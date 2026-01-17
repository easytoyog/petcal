/* eslint-disable */

// -------- Imports --------
const admin = require("firebase-admin");
const { getFirestore, FieldPath } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getAuth } = require("firebase-admin/auth");

const {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { DateTime } = require("luxon");

// -------- Init --------
admin.initializeApp();
const db = getFirestore();

// ---------- Small helpers ----------
// add these helpers near the top (you already have similar ones)
// New helpers
function sendKeyDocRef(uid, utcKey) {
  return db.collection("owners").doc(uid)
    .collection("stats").doc("dailyStepsNudge")
    .collection("sends").doc(utcKey); // canonical per-UTC-day
}

async function tryReserveSend(uid, todayKey, tz) {
  const ref = sendKeyDocRef(uid, todayKey);
  await ref.create({
    reservedAt: admin.firestore.FieldValue.serverTimestamp(),
    tz: tz || "UTC",
    status: "reserved", // reserved | sent | failed
  }); // throws if already exists
  return ref;
}

async function markSendStatus(ref, status, extra = {}) {
  await ref.set({
    status,
    ...extra,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
}

function utcDayKey(date = DateTime.utc()) {
  return date.toUTC().toFormat("yyyy-LL-dd");
}

async function getOwnerName(uid) {
  try {
    const p = await db.collection("public_profiles").doc(uid).get();
    const n = p.exists ? String(p.get("displayName") || "").trim() : "";
    return n || "Someone";
  } catch (e) {                          // ← this trips ESLint/parser
    return "Someone";
  }
}

async function getParkNameSafe(parkId) {
  try {
    const p = await db.collection("parks").doc(parkId).get();
    const n = p.exists ? String(p.get("name") || "").trim() : "";
    return n || "this park";
  } catch (e) {                         // ← same here
    return "this park";
  }
}

function dateToDayUTCString(d) {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`; // "YYYY-MM-DD" (UTC)
}

function formatWalkMinutes(totalMinutes) {
  const m = Math.max(0, Math.round(totalMinutes || 0));
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  return rm ? `${h}h ${rm}m` : `${h}h`;
}

function todayWindowInTz(tz) {
  const now = DateTime.now().setZone(tz || "UTC");
  const start = now.startOf("day");
  const end = start.plus({ days: 1 });
  return {
    start: start.toJSDate(),
    end: end.toJSDate(),
    todayKey: start.toFormat("yyyy-LL-dd"),
    now, // Luxon DateTime
  };
}

// --- Message rotation helpers ---
function hashStr(s) {
  // simple djb2
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h) + s.charCodeAt(i);
  return h >>> 0; // uint32
}

function pickDailyRecapBody({ uid, dayKey, steps, minutes, niceTime }) {
  // pools: use short, cheerful lines that fit push limits
  const withTime = [
    (s,t) => `🐶✨ What a day! You and your buddy logged ${s.toLocaleString()} steps and ${t} of pure together-time. Tails up!`,
    (s,t) => `🌟 Proud parent moment: ${s.toLocaleString()} steps and ${t} outside together. Your pup’s heart (and paws) thank you.`,
    (s,t) => `🥇 Gold-star walk team! ${s.toLocaleString()} steps + ${t} exploring the world—what a gift to your pup.`,
    (s,t) => `💚 Quality time unlocked: ${s.toLocaleString()} steps and ${t} of sniffing, strolling, and smiles. Nice work!`,
    (s,t) => `🦴 You showed up today—${s.toLocaleString()} steps and ${t} making memories with your best friend. So good!`,
    (s,t) => `🌿 Fresh-air champions: ${s.toLocaleString()} steps over ${t}. That’s love, routine, and wag-worthy effort.`,
    (s,t) => `👏 High-five to the hooman! ${s.toLocaleString()} steps and ${t} focused on your pup. That’s real dedication.`,
    (s,t) => `🏅 You crushed it: ${s.toLocaleString()} steps + ${t} of adventure. Your pup’s zoomies are well earned!`,
    (s,t) => `💫 Everyday hero stuff—${s.toLocaleString()} steps and ${t} together. Healthy, happy, and deeply loved.`,
    (s,t) => `🎉 Big win for the pack: ${s.toLocaleString()} steps and ${t} of bond-building. Keep that momentum!`,
    (s,t) => `🌞 Sunshine or not, you did it—${s.toLocaleString()} steps and ${t} walking with your pup. Heart full, paws tired.`,
    (s,t) => `🐾 Pack pride! ${s.toLocaleString()} steps and ${t} outside. Little habits, huge love. Way to show up.`,
    (s,t) => `🧡 Together time FTW: ${s.toLocaleString()} steps in ${t}. Your pup will be dreaming happy tonight.`,
    (s,t) => `🚶‍♀️+🐕 = 💖 ${s.toLocaleString()} steps and ${t} of connection. That’s the good stuff—nicely done!`,
    (s,t) => `🌈 You made today count—${s.toLocaleString()} steps and ${t} focused on your four-legged fave. Proud of you!`,
    (s,t) => `🔥 Consistency looks good on you: ${s.toLocaleString()} steps and ${t} out there together. Keep it rolling!`,
  ];
  const stepsOnly = [
    s => `🐶💖 You and your pup got in ${s.toLocaleString()} steps today—love that quality time`,
    s => `🌟 Nice! ${s.toLocaleString()} steps together today`,
    s => `👏 Great job—${s.toLocaleString()} steps with your best buddy`,
    s => `🐾 Way to go! ${s.toLocaleString()} steps logged`,
    s => `🏅 Strong day: ${s.toLocaleString()} steps`,
    s => `🌿 You moved! ${s.toLocaleString()} steps today`,
  ];

  const zeroDay = [
    () => `🐾 Still time to make memories—try a quick 10-minute lap with your best buddy`,
    () => `🌿 A short stroll feels great—how about a quick loop?`,
    () => `🐕 A little walk goes a long way—want to step outside?`,
    () => `💚 Tiny wins count—take a few minutes with your pup`,
    () => `✨ Quick stretch break? Your buddy will love it`,
    () => `🙂 Even a short walk can brighten the day`,
  ];

  let pool;
  if (steps > 0 && minutes > 0 && niceTime) pool = withTime;
  else if (steps > 0) pool = stepsOnly;
  else pool = zeroDay;

  const seed = `${uid}|${dayKey}`;
  const idx = hashStr(seed) % pool.length;

  const template = pool[idx];
  return (niceTime ? template(steps, niceTime) : template(steps));
}


async function sumStepsAndMinutesForUserDay(uid, start, end) {
  const snap = await db
    .collection("owners").doc(uid)
    .collection("walks")
    .where("endedAt", ">=", start)
    .where("endedAt", "<", end)
    .select("steps", "durationSec")
    .get();

  let steps = 0;
  let minutes = 0;
  snap.forEach(d => {
    const s = d.get("steps");
    if (typeof s === "number" && isFinite(s)) steps += s;
    const dur = d.get("durationSec");
    if (typeof dur === "number" && isFinite(dur)) minutes += dur / 60;
  });
  return { steps, minutes: Math.round(minutes) };
}

async function getOwnerDisplayName(uid) {
  try {
    const o = await db.collection("owners").doc(uid).get();
    if (o.exists) {
      const d = o.data() || {};
      const first = String(d.firstName || d.first_name || "").trim();
      const last  = String(d.lastName  || d.last_name  || "").trim();
      const full  = (first && last) ? `${first} ${last}` : (d.displayName || "").toString().trim();
      if (full) return full.slice(0, 60);
    }
  } catch (_) {}
  try {
    const p = await db.collection("public_profiles").doc(uid).get();
    if (p.exists) {
      const n = String(p.get("displayName") || "").trim();
      if (n) return n.slice(0, 60);
    }
  } catch (_) {}
  return "Someone";
}

async function getParkName(parkId) {
  try {
    const snap = await db.collection("parks").doc(parkId).get();
    const n = snap.exists ? String(snap.get("name") || "").trim() : "";
    return n || "this park";
  } catch (_) {
    return "this park";
  }
}

/**
 * Close the latest open visit for a park/user (one with null checkOutAt).
 * Returns true if a visit was closed; false if none found.
 */
async function closeLatestOpenVisit(opts) {
  const { parkId, userId } = opts;
  const closedBy = opts.closedBy || "unknown";
  const checkoutDate = opts.checkoutDate || new Date();

  const q = await db
    .collection("park_visits")
    .where("parkId", "==", parkId)
    .where("userId", "==", userId)
    .where("checkOutAt", "==", null)
    .orderBy("checkInAt", "desc")
    .limit(1)
    .get();

  if (q.empty) return false;

  const doc = q.docs[0];
  const data = doc.data();

  let checkInAt = new Date();
  if (data && data.checkInAt && typeof data.checkInAt.toDate === "function") {
    checkInAt = data.checkInAt.toDate();
  }

  const minutes = Math.max(
    0,
    Math.round((checkoutDate.getTime() - checkInAt.getTime()) / 60000)
  );

  await doc.ref.set(
    {
      checkOutAt: admin.firestore.Timestamp.fromDate(checkoutDate),
      durationMinutes: minutes,
      closedBy,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  return true;
}

// =========================
// Check-in: notify friends (MUTUAL ONLY) + create visit row
// =========================
exports.notifyFriendCheckIn = onDocumentCreated(
  "parks/{parkId}/active_users/{userId}",
  async (event) => {
    const parkId = event.params.parkId;
    const userId = event.params.userId; // the user who just checked in

    const [ownerName, parkName] = await Promise.all([
      getOwnerDisplayName(userId),
      getParkName(parkId),
    ]);

    // All users *this user* friended
    const friendsSnap = await db
      .collection("friends")
      .doc(userId)
      .collection("userFriends")
      .get();

    for (const friendDoc of friendsSnap.docs) {
      const friendId = friendDoc.id;
      if (!friendId || friendId === userId) continue; // never notify self

      // Only notify if friendship is MUTUAL: friend also has userId in their list
      const mutual = await db
        .collection("friends").doc(friendId)
        .collection("userFriends").doc(userId)
        .get();
      if (!mutual.exists) continue;

      // Only if that friend liked this park
      const liked = await db
        .collection("owners").doc(friendId)
        .collection("likedParks").doc(parkId)
        .get();
      if (!liked.exists) continue;

      // Friend's FCM token
      const friendOwner = await db.collection("owners").doc(friendId).get();
      const fcmToken = friendOwner.exists ? friendOwner.get("fcmToken") : null;
      if (!fcmToken || !String(fcmToken).trim()) continue;

      try {
        await getMessaging().send({
          token: fcmToken,
          notification: {
            title: "Friend at your favorite park!",
            body: `${ownerName} checked into ${parkName}`,
          },
          data: {
            type: "friend_checkin",
            parkId,
            friendId: userId,
            friendName: ownerName,
            parkName,
            click_action: "FLUTTER_NOTIFICATION_CLICK",
          },
          android: { priority: "high" },
          apns: { payload: { aps: { sound: "default" } } },
        });
      } catch (e) {
        const code = (e && e.code) ? String(e.code) : "";
        if (code.includes("registration-token-not-registered")) {
          await db.collection("owners").doc(friendId)
            .set({ fcmToken: admin.firestore.FieldValue.delete() }, { merge: true });
        } else {
          console.error("friend_checkin push failed for", friendId, e);
        }
      }
    }
  }
);

exports.autoCheckoutInactiveUsers = onSchedule({ schedule: "every 10 minutes" }, async () => {
  const now = new Date();
  const THREE_HOURS = 3 * 60 * 60 * 1000;
  const threeHoursAgo = new Date(now.getTime() - THREE_HOURS);
  const twelveHoursAhead = new Date(now.getTime() + 12 * 60 * 60 * 1000);

  const collectRefs = async () => {
    const uniq = new Map();

    // 1) Properly stamped & stale
    const q1 = await db.collectionGroup("active_users")
      .where("checkedInAt", "<", threeHoursAgo).get();
    q1.docs.forEach(d => uniq.set(d.ref.path, d.ref));

    // 2) Bad future timestamps (client clock wrong)
    const q3 = await db.collectionGroup("active_users")
      .where("checkedInAt", ">", twelveHoursAhead).get();
    q3.docs.forEach(d => uniq.set(d.ref.path, d.ref));

    // 3) Legacy field `checkInAt` (no checkedInAt)
    const qLegacy = await db.collectionGroup("active_users")
      .where("checkInAt", "<", threeHoursAgo).get();
    qLegacy.docs.forEach(d => uniq.set(d.ref.path, d.ref));

    // 4) Unknown/missing `checkedInAt`: can’t query “missing”, so scan a bounded window
    // Pull candidates by createdAt and inspect in process.
    const qCreated = await db.collectionGroup("active_users")
      .where("createdAt", "<", threeHoursAgo).get();
    qCreated.docs.forEach(d => uniq.set(d.ref.path, d.ref));

    return Array.from(uniq.values());
  };

  const refs = await collectRefs();
  if (!refs.length) return null;

  // Filter & normalize before deciding to delete
  const toDelete = [];
  for (const ref of refs) {
    const snap = await ref.get();
    if (!snap.exists) continue;
    const x = snap.data() || {};

    // Prefer checkedInAt; fallback to legacy checkInAt; fallback to createdAt
    const ts = x.checkedInAt || x.checkInAt || x.createdAt;
    const checkInDate = (ts && typeof ts.toDate === "function") ? ts.toDate() : null;

    // If we still can’t tell when they checked in, or it’s clearly stale → delete
    if (!checkInDate || checkInDate < threeHoursAgo || checkInDate > twelveHoursAhead) {
      toDelete.push(ref);
    }
  }

  if (!toDelete.length) return null;

  // Bulk delete → will trigger onDocumentDeleted to decrement counts + close visit
  const writer = db.bulkWriter();
  toDelete.forEach(r => writer.delete(r));
  await writer.close();

  console.log(`[autoCheckout] Deleted ${toDelete.length} stale active_users.`);
  return null;
});



// =========================
// Admin callables
// =========================
exports.setAdmin = onCall({ enforceAppCheck: true }, async (request) => {
  if (!request.auth || !request.auth.token || request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Only admins can set admin.");
  }

  const body = request.data || {};
  const uid = body.uid;
  const makeAdmin = body.makeAdmin;

  if (typeof uid !== "string" || typeof makeAdmin !== "boolean") {
    throw new HttpsError("invalid-argument", "Provide { uid: string, makeAdmin: boolean }");
  }

  const auth = getAuth();
  const user = await auth.getUser(uid);
  const existing = user.customClaims || {};
  const merged = { ...existing, admin: makeAdmin };

  await auth.setCustomUserClaims(uid, merged);
  await auth.revokeRefreshTokens(uid);
  return { ok: true, uid, claims: merged };
});

exports.setAdminByEmail = onCall({ enforceAppCheck: true }, async (request) => {
  if (!request.auth || !request.auth.token || request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Only admins can set admin.");
  }

  const body = request.data || {};
  const email = body.email;
  const makeAdmin = body.makeAdmin;

  if (typeof email !== "string" || typeof makeAdmin !== "boolean") {
    throw new HttpsError("invalid-argument", "Provide { email: string, makeAdmin: boolean }");
  }

  const auth = getAuth();
  const user = await auth.getUserByEmail(email);
  const existing = user.customClaims || {};
  const merged = { ...existing, admin: makeAdmin };

  await auth.setCustomUserClaims(user.uid, merged);
  await auth.revokeRefreshTokens(user.uid);
  return { ok: true, uid: user.uid, claims: merged };
});

// =========================
/* userCount triggers (tamper-proof) + visit sync */
// =========================
exports.onCheckInIncrementCount = onDocumentCreated(
  "parks/{parkId}/active_users/{uid}",
  async (event) => {
    const parkId = event.params.parkId;
    const uid = event.params.uid;

    await db.collection("parks").doc(parkId).update({
      userCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // read checkedInAt from the new doc
    const payload =
      event.data && typeof event.data.data === "function" ? event.data.data() : {};
    let checkedInAt = new Date();
    if (payload && payload.checkedInAt && typeof payload.checkedInAt.toDate === "function") {
      checkedInAt = payload.checkedInAt.toDate();
    }

    try {
      await closeLatestOpenVisit({
        parkId,
        userId: uid,
        closedBy: "system(auto-close-on-new-checkin)",
        checkoutDate: checkedInAt,
      });
    } catch (e) {
      console.warn("closeLatestOpenVisit failed; continuing:", e);
    }

    try {
      const day = dateToDayUTCString(checkedInAt);
      await db.collection("park_visits").add({
        parkId,
        userId: uid,
        checkInAt: admin.firestore.Timestamp.fromDate(checkedInAt),
        checkOutAt: null,
        durationMinutes: null,
        day, // for reporting/grouping
        openedBy: uid,
        closedBy: null,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log("park_visits: created for", { parkId, uid });
    } catch (e) {
      console.error("Failed to create park_visits:", e);
    }
  }
);

exports.onCheckOutDecrementCount = onDocumentDeleted(
  "parks/{parkId}/active_users/{uid}",
  async (event) => {
    const parkId = event.params.parkId;
    const uid = event.params.uid;

    await db.collection("parks").doc(parkId).update({
      userCount: admin.firestore.FieldValue.increment(-1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    try {
      await closeLatestOpenVisit({
        parkId,
        userId: uid,
        closedBy: "system(or-user)",
      });
    } catch (e) {
      console.error("Failed to close park_visits on checkout:", e);
    }
  }
);

// =========================
// Public profile mirror
// =========================
exports.mirrorOwnerToPublicProfile = onDocumentWritten(
  "owners/{uid}",
  async (event) => {
    const uid = event.params.uid;
    const pubRef = db.collection("public_profiles").doc(uid);

    const afterSnap = event.data && event.data.after ? event.data.after : null;
    const after = afterSnap && typeof afterSnap.data === "function" ? afterSnap.data() : null;

    if (!after) {
      try { await pubRef.delete(); } catch (_) {}
      return;
    }

    const firstName = typeof after.firstName === "string" ? after.firstName.trim() : "";
    const lastName  = typeof after.lastName === "string" ? after.lastName.trim()  : "";
    let displayName = firstName && lastName ? `${firstName} ${lastName}`.trim()
                     : (after.displayName ? String(after.displayName).trim() : "");

    const photoUrl = typeof after.photoUrl === "string" ? after.photoUrl : undefined;

    const publicData = {
      displayName: (displayName || "User").slice(0, 60),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (photoUrl) publicData.photoUrl = photoUrl;

    await pubRef.set(publicData, { merge: true });
  }
);

// =========================
// Daily steps recap (with local time + minutes)
// =========================
exports.sendDailyStepsRecap = onSchedule({ schedule: "every 5 minutes", timeZone: "UTC" }, async () => {
  const ownersSnap = await db.collection("owners").where("fcmToken", "!=", null).get();
  const owners = ownersSnap.docs.filter(d => {
    const x = d.data() || {};
    return x.dailyStepsOptIn !== false && typeof x.fcmToken === "string" && x.fcmToken.trim();
  });

  const seenTokens = new Set();
  const chunk = (arr, n) => arr.reduce((a,_,i)=> (i%n? a[a.length-1].push(arr[i]) : a.push([arr[i]]), a), []);

  for (const group of chunk(owners, 50)) {
    await Promise.all(group.map(async (doc) => {
      const uid = doc.id;
      const data = doc.data() || {};
      const tz = typeof data.tz === "string" && data.tz ? data.tz : "UTC";
      const token = String(data.fcmToken || "").trim();
      if (!token) return;

      // token de-dupe across owners
      if (seenTokens.has(token)) return;
      seenTokens.add(token);

      let win = todayWindowInTz(tz);
      if (!win.now.isValid) win = todayWindowInTz("UTC");

      // only send between 21:00–21:09 local time
      if (win.now.hour !== 21 || win.now.minute >= 10) return;

      const utcKey = utcDayKey();
      const localKey = win.todayKey;

      let sendRef;
      try {
        sendRef = await tryReserveSend(uid, utcKey, tz);
        await markSendStatus(sendRef, "reserved", { localDay: localKey });
      } catch (e) {
        return; // already reserved/sent for this UTC day
      }

      const { steps, minutes } = await sumStepsAndMinutesForUserDay(uid, win.start, win.end);
      const niceTime = minutes > 0 ? formatWalkMinutes(minutes) : null;
      const body = pickDailyRecapBody({ uid, dayKey: localKey, steps, minutes, niceTime });

      try {
        await getMessaging().send({
          token,
          notification: { title: "Daily Dog Walk Recap", body },
          data: {
            type: "daily_steps",
            utcDay: utcKey,
            localDay: localKey,
            steps: String(steps),
            minutes: String(minutes),
            click_action: "FLUTTER_NOTIFICATION_CLICK",
          },
          android: { notification: { channelId: "daily_reminders", priority: "HIGH" } },
          apns: { payload: { aps: { sound: "default" } } },
        });
        await markSendStatus(sendRef, "sent", { steps, minutes });
      } catch (e) {
        await markSendStatus(sendRef, "failed", { error: String((e && e.message) || e) });
      }
    }));
  }
  return null;
});


// =========================
// Park chat broadcast (unchanged)
// =========================
function toSafeTopic(s) {
  return s.replace(/[^A-Za-z0-9_\-\.~%]/g, '_');
}
const chunk = (arr, n) =>
  arr.reduce((a,_,i)=> (i%n? a[a.length-1].push(arr[i]) : a.push([arr[i]]), a), []);

exports.notifyParkChat = require("firebase-functions/v2/firestore")
  .onDocumentCreated("parks/{parkId}/chat/{messageId}", async (event) => {
    const { parkId, messageId } = event.params;
    const msg = event.data && typeof event.data.data === "function" ? event.data.data() : {};
    const senderId = String(msg.senderId || "");
    const text = String(msg.text || "").slice(0, 120);
    if (!text) return;

    let parkName = "this park";
    try {
      const parkSnap = await db.collection("parks").doc(parkId).get();
      const n = parkSnap.exists ? parkSnap.get("name") : null;
      if (typeof n === "string" && n.trim()) parkName = n.trim();
    } catch (_) {}

    console.log("notifyParkChat fanout → park:", parkId, "messageId:", messageId, "sender:", senderId);

    const subsSnap = await db
      .collectionGroup("chat_subscriptions")
      .where("parkId", "==", parkId)
      .where("enabled", "==", true)
      .get();

    let tokens = [];
    const ownerIds = Array.from(new Set(subsSnap.docs.map(d => d.ref.parent.parent.id)))
      .filter(id => id && id !== senderId);

    for (const group of chunk(ownerIds, 10)) {
      const ownersSnap = await db.collection("owners")
        .where(FieldPath.documentId(), "in", group)
        .select("fcmToken")
        .get();
      ownersSnap.forEach(doc => {
        const t = doc.get("fcmToken");
        if (typeof t === "string" && t.trim()) tokens.push({ uid: doc.id, token: t.trim() });
      });
    }

    const seen = new Set();
    tokens = tokens.filter(t => !seen.has(t.token) && seen.add(t.token));
    if (!tokens.length) {
      console.log("No valid tokens for park", parkId);
      return;
    }

    const payload = {
      notification: { title: `New message in ${parkName}`, body: text },
      data: { parkId, senderId, messageId, type: "park_chat", click_action: "FLUTTER_NOTIFICATION_CLICK" },
      android: { priority: "high" },
      apns: { payload: { aps: { sound: "default" } } },
    };

    let success = 0, failure = 0;
    for (const group of chunk(tokens, 500)) {
      const res = await getMessaging().sendEachForMulticast({
        tokens: group.map(x => x.token),
        ...payload,
      });
      success += res.successCount;
      failure += res.failureCount;

      for (let i = 0; i < res.responses.length; i++) {
        const r = res.responses[i];
        if (!r.success && r.error && String(r.error.code).includes("registration-token-not-registered")) {
          const dead = group[i];
          console.log("Cleaning dead token for uid", dead.uid);
          await db.collection("owners").doc(dead.uid)
            .set({ fcmToken: admin.firestore.FieldValue.delete() }, { merge: true });
        }
      }
    }

    console.log(`Chat fanout done → park=${parkId} success=${success} failure=${failure} recipients=${tokens.length}`);
  });

exports.mirrorVisit = onDocumentWritten('park_visits/{visitId}', async (event) => {
  const visitId = event.params.visitId;

  const afterSnap = (event.data && event.data.after) ? event.data.after : null;
  const beforeSnap = (event.data && event.data.before) ? event.data.before : null;
  const after = (afterSnap && typeof afterSnap.data === "function") ? afterSnap.data() : null;
  const before = (beforeSnap && typeof beforeSnap.data === "function") ? beforeSnap.data() : null;

  // Delete → remove mirrors
  if (!after) {
    if (before && before.userId && before.parkId) {
      await Promise.allSettled([
        db.collection('owners').doc(before.userId).collection('visit_history').doc(visitId).delete(),
        db.collection('parks').doc(before.parkId).collection('visit_history').doc(visitId).delete(),
      ]);
    }
    return;
  }

  const userId = after.userId;
  const parkId = after.parkId;
  const checkInAt = after.checkInAt;
  const checkOutAt = after.checkOutAt;
  const durationMinutes = after.durationMinutes;
  const day = after.day;

  if (typeof userId !== 'string' || typeof parkId !== 'string') return;

  const norm = {
    checkInAt: checkInAt ? checkInAt : admin.firestore.FieldValue.serverTimestamp(),
    checkOutAt: checkOutAt ? checkOutAt : null,
    durationMinutes: Number.isFinite(durationMinutes) ? durationMinutes : null,
    day: (typeof day === 'string' && day) ? day : dateToDayUTCString(new Date()),
  };

  const [ownerName, parkName] = await Promise.all([
    getOwnerName(userId),
    getParkNameSafe(parkId),
  ]);

  const mirrorData = {
    ...after,
    ...norm,
    visitId,
    ownerName,
    parkName,
    mirroredAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  await Promise.allSettled([
    db.collection('owners').doc(userId).collection('visit_history').doc(visitId).set(mirrorData, { merge: true }),
    db.collection('parks').doc(parkId).collection('visit_history').doc(visitId).set(mirrorData, { merge: true }),
  ]);
});

exports.onActiveUserCreated = onDocumentCreated(
  "parks/{parkId}/active_users/{uid}",
  async (event) => {
    const ref = event.data && event.data.ref ? event.data.ref : null;
    if (!ref) return;
     const d = (event.data && typeof event.data.data === "function")
   ? event.data.data()
   : {};

    // Normalize to `checkedInAt` (the field your cleaner expects)
    const updates = {
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (!d.checkedInAt && d.checkInAt && typeof d.checkInAt.toDate === "function") {
      updates.checkedInAt = d.checkInAt;        // migrate if client wrote checkInAt
    } else if (!d.checkedInAt) {
      updates.checkedInAt = admin.firestore.FieldValue.serverTimestamp();
    }

    if (!d.createdAt) {
      updates.createdAt = admin.firestore.FieldValue.serverTimestamp();
    }

    await ref.set(updates, { merge: true });
  }
);

exports.onDmMessageCreated = onDocumentCreated(
  "dm_threads/{threadId}/messages/{messageId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const { threadId } = event.params;
    const msg = snap.data() || {};

    const senderId = String(msg.senderId || "");
    const text = String(msg.text || "").trim();
    if (!senderId || !text) return;

    // Load thread to find recipient
    const threadSnap = await db.collection("dm_threads").doc(threadId).get();
    if (!threadSnap.exists) return;

    const thread = threadSnap.data() || {};
    const participants = Array.isArray(thread.participants) ? thread.participants : [];
    if (participants.length !== 2) return;

    const recipientId = participants.find((u) => u !== senderId);
    if (!recipientId) return;

    // Fetch recipient token
    const recipientOwnerSnap = await db.collection("owners").doc(recipientId).get();
    const token = recipientOwnerSnap.exists ? recipientOwnerSnap.get("fcmToken") : null;
    if (!token || !String(token).trim()) return;

    // Sender display name (safe)
    const senderName = await getOwnerDisplayName(senderId); // you already have this helper

    // Send push (with click_action so Flutter can route)
    try {
      await getMessaging().send({
        token: String(token).trim(),
        notification: {
          title: senderName,
          body: text.length > 120 ? text.slice(0, 117) + "..." : text,
        },
        data: {
          type: "dm",
          threadId,
          senderId,
          senderName,
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
        android: { priority: "high" },
        apns: { payload: { aps: { sound: "default" } } },
      });
    } catch (e) {
      const code = (e && e.code) ? String(e.code) : "";
      if (code.includes("registration-token-not-registered")) {
        await db.collection("owners").doc(recipientId)
          .set({ fcmToken: admin.firestore.FieldValue.delete() }, { merge: true });
      } else {
        console.error("dm push failed:", threadId, recipientId, e);
      }
    }
  }
);