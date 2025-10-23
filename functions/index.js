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
    (s,t) => `🐶💖 Pawsome day! ${s.toLocaleString()} steps and ${t} of together-time`,
    (s,t) => `🐾 You guys got moving—${s.toLocaleString()} steps and ${t}!`,
    (s,t) => `🌟 Nice work! ${s.toLocaleString()} steps + ${t} out and about`,
    (s,t) => `👏 High fives! ${s.toLocaleString()} steps and ${t} with your pup`,
    (s,t) => `💚 Quality time: ${s.toLocaleString()} steps, ${t} together`,
    (s,t) => `🏅 You crushed it—${s.toLocaleString()} steps and ${t}!`,
    (s,t) => `🌿 Fresh air score: ${s.toLocaleString()} steps + ${t}`,
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

async function alreadySentToday(uid, todayKey) {
  const doc = await db
    .collection("owners").doc(uid)
    .collection("stats").doc("dailyStepsNudge")
    .get();
  return doc.exists && doc.get("lastSentDay") === todayKey;
}

async function markSent(uid, todayKey, tz) {
  await db.collection("owners").doc(uid)
    .collection("stats").doc("dailyStepsNudge")
    .set({
      lastSentDay: todayKey,
      lastSentAt: admin.firestore.FieldValue.serverTimestamp(),
      tz: tz || "UTC",
    }, { merge: true });
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

// =========================
// Auto-checkout (3 hours) — runs every 10 minutes
// =========================
exports.autoCheckoutInactiveUsers = onSchedule(
  { schedule: "every 10 minutes" },
  async () => {
    const threeHoursAgo = new Date(Date.now() - 3 * 60 * 60 * 1000);

    const parksSnapshot = await db.collection("parks").get();
    for (const parkDoc of parksSnapshot.docs) {
      const activeUsersRef = parkDoc.ref.collection("active_users");
      const activeUsersSnapshot = await activeUsersRef.get();

      for (const userDoc of activeUsersSnapshot.docs) {
        const checkedInAt = userDoc.get("checkedInAt");
        const hasToDate =
          checkedInAt && typeof checkedInAt.toDate === "function";

        if (hasToDate && checkedInAt.toDate() < threeHoursAgo) {
          // Deleting triggers onDocumentDeleted below.
          await userDoc.ref.delete();
        }
      }
    }
    return null;
  }
);

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
exports.sendDailyStepsRecap = onSchedule(
  { schedule: "every 5 minutes", timeZone: "UTC" },
  async () => {
    // All owners that can receive pushes (opt-out supported with dailyStepsOptIn=false)
    const ownersSnap = await db.collection("owners")
      .where("fcmToken", "!=", null)
      .get();

    const owners = ownersSnap.docs.filter(d => {
      const data = d.data() || {};
      return data.dailyStepsOptIn !== false
          && typeof data.fcmToken === "string"
          && data.fcmToken.trim();
    });

    const chunk = (arr, n) =>
      arr.reduce((a,_,i)=> (i%n? a[a.length-1].push(arr[i]) : a.push([arr[i]]), a), []);

    for (const group of chunk(owners, 50)) {
      await Promise.all(group.map(async (doc) => {
        const uid = doc.id;
        const data = doc.data() || {};
        const tz = typeof data.tz === "string" && data.tz ? data.tz : "UTC";
        const token = data.fcmToken;

        let win = todayWindowInTz(tz);
        if (!win.now.isValid) win = todayWindowInTz("UTC");

        // Send between 21:00–21:09 local time, once per day
        if (win.now.hour !== 21 || win.now.minute >= 10) return;
        if (await alreadySentToday(uid, win.todayKey)) return;

        const { steps, minutes } = await sumStepsAndMinutesForUserDay(uid, win.start, win.end);

        const niceTime = minutes > 0 ? formatWalkMinutes(minutes) : null;

        // ——— Upbeat, “feel-good” copy ———
        const body = pickDailyRecapBody({
          uid,
          dayKey: win.todayKey,
          steps,
          minutes,
          niceTime,
        });

        try {
          await getMessaging().send({
            token,
            notification: {
              title: "Daily Dog Walk Recap",
              body,
            },
            data: {
              type: "daily_steps",
              day: win.todayKey,
              steps: String(steps),
              minutes: String(minutes),
              click_action: "FLUTTER_NOTIFICATION_CLICK",
            },
            android: {
              notification: { channelId: "daily_reminders", priority: "HIGH" },
            },
            apns: { payload: { aps: { sound: "default" } } },
          });
          await markSent(uid, win.todayKey, tz);
        } catch (e) {
          console.error("Failed sending daily steps to", uid, e);
        }
      }));
    }
    return null;
  }
);


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
