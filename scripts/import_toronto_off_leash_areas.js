const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

const DEFAULT_CSV_PATH = "/Users/bill/Documents/toronto_dog_off_leash_areas.csv";
const DEFAULT_SERVICE_ACCOUNT = path.resolve(
  __dirname,
  "..",
  "pet-app-38a26-firebase-adminsdk-4l7ed-bab7e02cde.json",
);
const OFF_LEASH_SERVICE = "Off-leash Dog Park";

function parseArgs(argv) {
  const args = {
    csv: DEFAULT_CSV_PATH,
    write: false,
    verbose: false,
  };

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--write") {
      args.write = true;
    } else if (arg === "--verbose") {
      args.verbose = true;
    } else if (arg === "--csv" && argv[i + 1]) {
      args.csv = argv[++i];
    } else if (arg === "--help") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function printHelp() {
  console.log(`
Usage:
  node scripts/import_toronto_off_leash_areas.js [--csv /path/file.csv] [--write] [--verbose]

Defaults to dry-run. Add --write to actually create missing parks.
  `.trim());
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    const next = text[i + 1];

    if (ch === '"') {
      if (inQuotes && next === '"') {
        field += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (ch === "," && !inQuotes) {
      row.push(field);
      field = "";
      continue;
    }

    if ((ch === "\n" || ch === "\r") && !inQuotes) {
      if (ch === "\r" && next === "\n") i++;
      row.push(field);
      field = "";
      const hasContent = row.some((value) => value !== "");
      if (hasContent) rows.push(row);
      row = [];
      continue;
    }

    field += ch;
  }

  if (field.length || row.length) {
    row.push(field);
    if (row.some((value) => value !== "")) rows.push(row);
  }

  if (!rows.length) return [];
  const headers = rows[0].map((h) => h.trim());
  return rows.slice(1).map((values) => {
    const record = {};
    headers.forEach((header, index) => {
      record[header] = (values[index] || "").trim();
    });
    return record;
  });
}

function generateParkID(latitude, longitude, placeID) {
  const trimmedPlaceID = String(placeID)
    .replaceAll("/", "")
    .replaceAll("\\", "")
    .replaceAll(" ", "");
  const trimmedLat = Number(latitude).toFixed(1).replaceAll(" ", "");
  const trimmedLng = Number(longitude).toFixed(1).replaceAll(" ", "");
  return `${trimmedPlaceID}_${trimmedLat}_${trimmedLng}`;
}

function normalizeName(value) {
  return String(value || "")
    .toLowerCase()
    .replaceAll("&", " and ")
    .replaceAll("'", "")
    .replaceAll(/[^a-z0-9]+/g, " ")
    .trim()
    .replaceAll(/\s+/g, " ");
}

function looseNormalizeName(value) {
  return normalizeName(value)
    .replaceAll(/\boff\b/g, " ")
    .replaceAll(/\bleash\b/g, " ")
    .replaceAll(/\bdog\b/g, " ")
    .replaceAll(/\barea\b/g, " ")
    .replaceAll(/\bpark\b/g, " ")
    .trim()
    .replaceAll(/\s+/g, " ");
}

function haversineMeters(aLat, aLng, bLat, bLng) {
  const earth = 6371000;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const lat1 = toRad(aLat);
  const lat2 = toRad(bLat);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * earth * Math.asin(Math.min(1, Math.sqrt(h)));
}

function toRad(deg) {
  return deg * Math.PI / 180;
}

function buildExistingIndexes(existingParks) {
  const byId = new Map();
  const byNormalized = new Map();
  const byLoose = new Map();

  for (const park of existingParks) {
    byId.set(park.id, park);

    const normalized = normalizeName(park.name);
    if (!byNormalized.has(normalized)) byNormalized.set(normalized, []);
    byNormalized.get(normalized).push(park);

    const loose = looseNormalizeName(park.name);
    if (!byLoose.has(loose)) byLoose.set(loose, []);
    byLoose.get(loose).push(park);
  }

  return { byId, byNormalized, byLoose };
}

function matchExistingPark(row, indexes) {
  const name = row.location_name;
  const latitude = Number(row.latitude);
  const longitude = Number(row.longitude);
  const generatedId = generateParkID(latitude, longitude, name);

  const exactId = indexes.byId.get(generatedId);
  if (exactId) {
    return { type: "id", park: exactId, distanceMeters: 0, generatedId };
  }

  const normalized = normalizeName(name);
  const loose = looseNormalizeName(name);

  const directCandidates = [
    ...(indexes.byNormalized.get(normalized) || []),
    ...(indexes.byLoose.get(loose) || []),
  ];

  const seen = new Set();
  const deduped = directCandidates.filter((park) => {
    if (seen.has(park.id)) return false;
    seen.add(park.id);
    return true;
  });

  let best = null;
  for (const park of deduped) {
    const distanceMeters = haversineMeters(
      latitude,
      longitude,
      park.latitude,
      park.longitude,
    );

    const existingNormalized = normalizeName(park.name);
    const existingLoose = looseNormalizeName(park.name);
    const exactName = existingNormalized === normalized;
    const looseName = loose && existingLoose && existingLoose === loose;
    const partialName = (
      existingNormalized.includes(normalized) ||
      normalized.includes(existingNormalized)
    );

    const withinExactThreshold = exactName && distanceMeters <= 1200;
    const withinLooseThreshold = looseName && distanceMeters <= 700;
    const withinPartialThreshold = partialName && distanceMeters <= 250;

    if (!withinExactThreshold && !withinLooseThreshold && !withinPartialThreshold) {
      continue;
    }

    const score = (exactName ? 3 : looseName ? 2 : 1) * 100000 - distanceMeters;
    if (!best || score > best.score) {
      best = {
        type: exactName ? "name+distance" : looseName ? "loose-name+distance" : "partial+distance",
        park,
        distanceMeters,
        score,
        generatedId,
      };
    }
  }

  if (!best) return { type: "missing", park: null, distanceMeters: null, generatedId };
  return best;
}

function buildCreatePayload(row) {
  const latitude = Number(row.latitude);
  const longitude = Number(row.longitude);
  const name = row.location_name;
  const id = generateParkID(latitude, longitude, name);

  return {
    id,
    name,
    latitude,
    longitude,
    services: [OFF_LEASH_SERVICE],
    isDogPark: true,
    source: {
      dataset: "toronto_dog_off_leash_areas",
      locationId: row.location_id || null,
      assetId: row.asset_id || null,
      address: row.address || null,
      parkFacilityUrl: row.park_facility_url || null,
      sourceResourceUrl: row.source_resource_url || null,
      importedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

function dedupeMissingRows(rows) {
  const byId = new Map();
  const collisions = [];

  for (const row of rows) {
    const generatedId = generateParkID(
      Number(row.latitude),
      Number(row.longitude),
      row.location_name,
    );

    if (byId.has(generatedId)) {
      collisions.push({
        id: generatedId,
        kept: byId.get(generatedId),
        skipped: row,
      });
      continue;
    }

    byId.set(generatedId, row);
  }

  return {
    rows: Array.from(byId.values()),
    collisions,
  };
}

function initAdmin() {
  const configuredPath = process.env.GOOGLE_APPLICATION_CREDENTIALS || DEFAULT_SERVICE_ACCOUNT;
  if (!fs.existsSync(configuredPath)) {
    throw new Error(`Service account file not found: ${configuredPath}`);
  }
  const serviceAccount = require(configuredPath);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    projectId: serviceAccount.project_id,
  });
}

async function loadExistingParks(db) {
  const snap = await db.collection("parks").get();
  return snap.docs.map((doc) => {
    const data = doc.data() || {};
    return {
      id: doc.id,
      name: String(data.name || ""),
      latitude: Number(data.latitude || 0),
      longitude: Number(data.longitude || 0),
      services: Array.isArray(data.services) ? data.services : [],
      isDogPark: data.isDogPark === true,
    };
  }).filter((park) => park.name && Number.isFinite(park.latitude) && Number.isFinite(park.longitude));
}

function buildUpdatePayload(existingPark) {
  const services = Array.isArray(existingPark.services) ? existingPark.services : [];
  const nextServices = services.includes(OFF_LEASH_SERVICE)
    ? services
    : [...services, OFF_LEASH_SERVICE];

  const shouldUpdateServices = nextServices.length !== services.length;
  const shouldUpdateDogPark = existingPark.isDogPark !== true;

  if (!shouldUpdateServices && !shouldUpdateDogPark) {
    return null;
  }

  return {
    services: nextServices,
    isDogPark: true,
  };
}

async function main() {
  const args = parseArgs(process.argv);
  initAdmin();

  const csvText = fs.readFileSync(args.csv, "utf8");
  const rows = parseCsv(csvText)
    .filter((row) => row.location_name && row.latitude && row.longitude);

  const db = admin.firestore();
  const existingParks = await loadExistingParks(db);
  const indexes = buildExistingIndexes(existingParks);

  const results = [];
  const rawMissingRows = [];
  const matchedParkIds = new Set();
  const parksToUpdate = [];

  for (const row of rows) {
    const match = matchExistingPark(row, indexes);
    results.push({ row, match });
    if (match.type === "missing") {
      rawMissingRows.push(row);
      continue;
    }

    if (!match.park || matchedParkIds.has(match.park.id)) {
      continue;
    }

    matchedParkIds.add(match.park.id);
    const updatePayload = buildUpdatePayload(match.park);
    if (updatePayload) {
      parksToUpdate.push({
        id: match.park.id,
        payload: updatePayload,
      });
    }
  }

  const { rows: missingRows, collisions } = dedupeMissingRows(rawMissingRows);

  const counts = results.reduce((acc, item) => {
    acc[item.match.type] = (acc[item.match.type] || 0) + 1;
    return acc;
  }, {});

  console.log(`CSV rows considered: ${rows.length}`);
  console.log(`Existing parks loaded: ${existingParks.length}`);
  console.log("Match summary:", counts);
  console.log(`Unique missing parks after ID dedupe: ${missingRows.length}`);
  console.log(`Existing matched parks needing activity update: ${parksToUpdate.length}`);
  if (collisions.length) {
    console.log(`ID collisions skipped: ${collisions.length}`);
  }

  if (args.verbose) {
    for (const item of results) {
      const { row, match } = item;
      const name = row.location_name;
      if (match.park) {
        console.log(
          `[MATCH:${match.type}] ${name} -> ${match.park.name} (${match.park.id})` +
          (match.distanceMeters != null ? ` @ ${Math.round(match.distanceMeters)}m` : ""),
        );
      } else {
        console.log(`[CREATE] ${name} (${match.generatedId})`);
      }
    }
  } else {
    const preview = missingRows.slice(0, 10).map((row) => row.location_name);
    if (preview.length) {
      console.log("First missing parks:", preview.join(", "));
    }
  }

  if (args.verbose && collisions.length) {
    for (const collision of collisions) {
      console.log(
        `[SKIP:collision] ${collision.skipped.location_name} shares generated ID ${collision.id} with ` +
        `${collision.kept.location_name}`,
      );
    }
  }

  if (!args.write) {
    console.log("Dry run complete. Re-run with --write to create missing parks.");
    return;
  }

  if (!missingRows.length && !parksToUpdate.length) {
    console.log("No missing parks to create or matched parks to update.");
    return;
  }

  const batchSize = 300;
  let created = 0;
  let updated = 0;

  for (let i = 0; i < missingRows.length; i += batchSize) {
    const slice = missingRows.slice(i, i + batchSize);
    const batch = db.batch();

    for (const row of slice) {
      const payload = buildCreatePayload(row);
      const ref = db.collection("parks").doc(payload.id);
      batch.set(ref, payload, { merge: false });
      created++;
    }

    await batch.commit();
  }

  for (let i = 0; i < parksToUpdate.length; i += batchSize) {
    const slice = parksToUpdate.slice(i, i + batchSize);
    const batch = db.batch();

    for (const item of slice) {
      const ref = db.collection("parks").doc(item.id);
      batch.set(ref, item.payload, { merge: true });
      updated++;
    }

    await batch.commit();
  }

  console.log(`Created ${created} missing parks.`);
  console.log(`Updated ${updated} existing parks with ${OFF_LEASH_SERVICE}.`);
}

main().catch((error) => {
  console.error("Import failed:", error);
  process.exit(1);
});
