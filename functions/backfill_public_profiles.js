/**
 * Backfills public_profiles/{uid} from owners/{uid}.
 *
 * Auth options:
 *  A) Service account file:
 *     export GOOGLE_APPLICATION_CREDENTIALS="/path/to/sa.json"
 *     node backfill_public_profiles.js
 *
 *  B) gcloud ADC:
 *     gcloud auth application-default login
 *     node backfill_public_profiles.js
 */

const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

/**
 * Initialize the Firebase Admin SDK using either an explicit
 * service account (GOOGLE_APPLICATION_CREDENTIALS) or ADC.
 */
function initAdmin() {
  const saPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;

  try {
    if (saPath && fs.existsSync(saPath)) {
      // Explicit service account
      // eslint-disable-next-line import/no-dynamic-require, global-require
      const serviceAccount = require(path.resolve(saPath));
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
        projectId: serviceAccount.project_id,
      });
      console.log(
        "Initialized Admin SDK with service account:",
        saPath
      );
      return;
    }

    // Application Default Credentials
    admin.initializeApp({
      credential: admin.credential.applicationDefault(),
    });
    console.log(
      "Initialized Admin SDK with application default credentials."
    );
  } catch (err) {
    console.error("Failed to initialize Firebase Admin SDK:", err);
    process.exit(1);
  }
}

/**
 * Build a display name from first/last or fallback displayName.
 * @param {object} src Owner document data
 * @returns {string} display name (≤60 chars)
 */
function buildDisplayName(src) {
  const srcSafe = src || {};
  const first = (srcSafe.firstName || "").toString().trim();
  const last = (srcSafe.lastName || "").toString().trim();
  const full = (first || last) ? (first + " " + last).trim() : "";
  const fallback = (srcSafe.displayName || "").toString().trim();
  return (full || fallback).slice(0, 60);
}

/**
 * Entry point: iterate owners and write public_profiles.
 */
async function main() {
  initAdmin();

  const db = admin.firestore();
  const FieldValue = admin.firestore.FieldValue;

  const ownersCol = db.collection("owners");
  const writer = db.bulkWriter();

  let processed = 0;
  let wrote = 0;
  let skipped = 0;

  console.log("Starting backfill from owners → public_profiles ...");

  const stream = ownersCol.stream();

  stream.on("data", (snap) => {
    processed += 1;
    const uid = snap.id;
    const data = snap.data() || {};

    const displayName = buildDisplayName(data);
    const rawPhoto = typeof data.photoUrl === "string"
      ? data.photoUrl.trim()
      : "";
    const photoUrl = rawPhoto.length ? rawPhoto : undefined;

    // Uncomment to skip empty mirrors:
    // if (!displayName && !photoUrl) { skipped += 1; return; }

    const publicData = {
      displayName,
      ...(photoUrl ? {photoUrl} : {}),
      updatedAt: FieldValue.serverTimestamp(),
    };

    const pubRef = db.collection("public_profiles").doc(uid);
    writer.set(pubRef, publicData, {merge: true});
    wrote += 1;

    if (processed % 500 === 0) {
      console.log(
        "Progress:",
        "processed=" + processed + ",",
        "wrote=" + wrote + ",",
        "skipped=" + skipped
      );
    }
  });

  await new Promise((resolve, reject) => {
    stream.on("end", resolve);
    stream.on("error", reject);
  });

  await writer.close();

  console.log("Backfill complete.");
  console.log(
    "Totals:",
    "processed=" + processed + ",",
    "wrote=" + wrote + ",",
    "skipped=" + skipped
  );
}

main().catch((err) => {
  console.error("Backfill failed:", err);
  process.exit(1);
});
