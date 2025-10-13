/* eslint-disable */

// -------- Imports --------
const admin = require("firebase-admin");
const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getAuth } = require("firebase-admin/auth");

const {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onCall, HttpsError } = require("firebase-functions/v2/https");

// -------- Init --------
admin.initializeApp();
const db = getFirestore();

// ---------- Helpers ----------
function dateToDayUTCString(d) {
  // "YYYY-MM-DD" (UTC)
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return y + "-" + m + "-" + day;
}

/**
 * Close the latest open visit for a park/user (one with null checkOutAt).
 * Returns true if a visit was closed; false if none found.
 */
async function closeLatestOpenVisit(opts) {
  const parkId = opts.parkId;
  const userId = opts.userId;
  const closedBy = opts.closedBy || "unknown";
  const checkoutDate = opts.checkoutDate || new Date();

  // Find most recent open visit
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
      closedBy: closedBy,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  return true;
}

/* =========================
   Check-in: notify friends + create visit row
   ========================= */

exports.notifyFriendCheckIn = onDocumentCreated(
  "parks/{parkId}/active_users/{userId}",
  async (event) => {
    const parkId = event.params.parkId;
    const userId = event.params.userId;

    // ----- Notify friends who liked this park (no visit writes here) -----
    const friendsSnap = await db
      .collection("friends")
      .doc(userId)
      .collection("userFriends")
      .get();

    for (let i = 0; i < friendsSnap.docs.length; i++) {
      const friendDoc = friendsSnap.docs[i];
      const friendId = friendDoc.id;

      const likedParkDoc = await db
        .collection("owners")
        .doc(friendId)
        .collection("likedParks")
        .doc(parkId)
        .get();

      if (likedParkDoc.exists) {
        const ownerDoc = await db.collection("owners").doc(friendId).get();
        const data = ownerDoc.exists ? ownerDoc.data() : {};
        const fcmToken = data && data.fcmToken;

        if (fcmToken) {
          await getMessaging().send({
            token: fcmToken,
            notification: {
              title: "Friend at your favorite park!",
              body: "Your friend just checked into a park you like.",
            },
            data: { parkId: parkId, friendId: userId },
          });
        }
      }
    }
  }
);


/* =========================
   Chat message: notify friends who like the park
   ========================= */

exports.notifyFriendChatMessage = onDocumentCreated(
  "parks/{parkId}/chat/{messageId}",
  async (event) => {
    const parkId = event.params.parkId;
    const payload =
      event.data && typeof event.data.data === "function"
        ? event.data.data()
        : {};
    const senderId = payload && payload.senderId ? payload.senderId : "";

    if (!senderId) return;

    const friendsSnap = await db
      .collection("friends")
      .doc(senderId)
      .collection("userFriends")
      .get();

    for (let i = 0; i < friendsSnap.docs.length; i++) {
      const friendDoc = friendsSnap.docs[i];
      const friendId = friendDoc.id;

      const likedParkDoc = await db
        .collection("owners")
        .doc(friendId)
        .collection("likedParks")
        .doc(parkId)
        .get();

      if (likedParkDoc.exists) {
        const ownerDoc = await db.collection("owners").doc(friendId).get();
        const data = ownerDoc.exists ? ownerDoc.data() : {};
        const fcmToken = data && data.fcmToken;

        if (fcmToken) {
          await getMessaging().send({
            token: fcmToken,
            notification: {
              title: "New message in your favorite park!",
              body: "Your friend posted in a park chat you like.",
            },
            data: {
              parkId: parkId,
              senderId: senderId,
              messageId: event.params.messageId,
            },
          });
        }
      }
    }
  }
);

/* =========================
   Auto-checkout (3 hours) — runs every 10 minutes
   ========================= */

exports.autoCheckoutInactiveUsers = onSchedule(
  { schedule: "every 10 minutes" },
  async () => {
    const threeHoursAgo = new Date(Date.now() - 3 * 60 * 60 * 1000);

    const parksSnapshot = await db.collection("parks").get();
    for (let p = 0; p < parksSnapshot.docs.length; p++) {
      const parkDoc = parksSnapshot.docs[p];
      const activeUsersRef = parkDoc.ref.collection("active_users");
      const activeUsersSnapshot = await activeUsersRef.get();

      for (let u = 0; u < activeUsersSnapshot.docs.length; u++) {
        const userDoc = activeUsersSnapshot.docs[u];
        const checkedInAt = userDoc.get("checkedInAt");
        const hasToDate =
          checkedInAt && typeof checkedInAt.toDate === "function";

        if (hasToDate && checkedInAt.toDate() < threeHoursAgo) {
          // Deleting the doc will trigger onDocumentDeleted below,
          // which decrements userCount and closes the visit.
          await userDoc.ref.delete();
        }
      }
    }
    return null;
  }
);

/* =========================
   Admin callables
   ========================= */

exports.setAdmin = onCall({ enforceAppCheck: true }, async (request) => {
  if (
    !request.auth ||
    !request.auth.token ||
    request.auth.token.admin !== true
  ) {
    throw new HttpsError("permission-denied", "Only admins can set admin.");
  }

  const body = request.data || {};
  const uid = body.uid;
  const makeAdmin = body.makeAdmin;

  if (typeof uid !== "string" || typeof makeAdmin !== "boolean") {
    throw new HttpsError(
      "invalid-argument",
      "Provide { uid: string, makeAdmin: boolean }"
    );
  }

  const auth = getAuth();
  const user = await auth.getUser(uid);
  const existing = user.customClaims || {};
  const merged = {};
  Object.keys(existing).forEach((k) => (merged[k] = existing[k]));
  merged.admin = makeAdmin;

  await auth.setCustomUserClaims(uid, merged);
  await auth.revokeRefreshTokens(uid);

  return { ok: true, uid: uid, claims: merged };
});

exports.setAdminByEmail = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (
      !request.auth ||
      !request.auth.token ||
      request.auth.token.admin !== true
    ) {
      throw new HttpsError("permission-denied", "Only admins can set admin.");
    }

    const body = request.data || {};
    const email = body.email;
    const makeAdmin = body.makeAdmin;

    if (typeof email !== "string" || typeof makeAdmin !== "boolean") {
      throw new HttpsError(
        "invalid-argument",
        "Provide { email: string, makeAdmin: boolean }"
      );
    }

    const auth = getAuth();
    const user = await auth.getUserByEmail(email);
    const existing = user.customClaims || {};
    const merged = {};
    Object.keys(existing).forEach((k) => (merged[k] = existing[k]));
    merged.admin = makeAdmin;

    await auth.setCustomUserClaims(user.uid, merged);
    await auth.revokeRefreshTokens(user.uid);

    return { ok: true, uid: user.uid, claims: merged };
  }
);

/* =========================
   userCount triggers (tamper-proof) + visit sync
   ========================= */

exports.onCheckInIncrementCount = onDocumentCreated(
  "parks/{parkId}/active_users/{uid}",
  async (event) => {
    const parkId = event.params.parkId;
    const uid = event.params.uid;

    // Increment park userCount
    await db.collection("parks").doc(parkId).update({
      userCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // ----- Visit history: close any dangling visit, then open a new one -----
    // Safely read the checkedInAt from the new active_users doc
    const payload =
      event.data && typeof event.data.data === "function"
        ? event.data.data()
        : {};
    let checkedInAt = new Date();
    if (payload && payload.checkedInAt && typeof payload.checkedInAt.toDate === "function") {
      checkedInAt = payload.checkedInAt.toDate();
    }

    // Try to close any previous open visit for this park/user
    try {
      await closeLatestOpenVisit({
        parkId: parkId,
        userId: uid,
        closedBy: "system(auto-close-on-new-checkin)",
        checkoutDate: checkedInAt,
      });
    } catch (e) {
      console.warn("closeLatestOpenVisit failed; continuing:", e);
    }

    // Always create a fresh visit record
    try {
      const day = dateToDayUTCString(checkedInAt);
      await db.collection("park_visits").add({
        parkId: parkId,
        userId: uid,
        checkInAt: admin.firestore.Timestamp.fromDate(checkedInAt),
        checkOutAt: null,
        durationMinutes: null,
        day: day,                 // for reporting/grouping
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

    // Decrement the counter
    await db.collection("parks").doc(parkId).update({
      userCount: admin.firestore.FieldValue.increment(-1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Close the latest open visit for this park/user
    try {
      await closeLatestOpenVisit({
        parkId: parkId,
        userId: uid,
        closedBy: "system(or-user)",
        // checkoutDate omitted -> use now()
      });
    } catch (e) {
      console.error("Failed to close park_visits on checkout:", e);
    }
  }
);

/* =========================
   Public profile mirror
   ========================= */

exports.mirrorOwnerToPublicProfile = onDocumentWritten(
  "owners/{uid}",
  async (event) => {
    const uid = event.params.uid;
    const pubRef = db.collection("public_profiles").doc(uid);

    // Get "after" snapshot safely (no optional chaining)
    const afterSnap =
      event.data && event.data.after ? event.data.after : null;
    const after =
      afterSnap && typeof afterSnap.data === "function"
        ? afterSnap.data()
        : null;

    // If owners/{uid} was deleted, delete public profile
    if (!after) {
      try {
        await pubRef.delete();
      } catch (e) {
        // ignore missing doc
      }
      return;
    }

    // Build displayName
    const firstName =
      after.firstName && typeof after.firstName === "string"
        ? after.firstName.trim()
        : "";
    const lastName =
      after.lastName && typeof after.lastName === "string"
        ? after.lastName.trim()
        : "";
    let displayName = "";
    if (firstName && lastName) {
      displayName = (firstName + " " + lastName).trim();
    } else if (after.displayName) {
      displayName = String(after.displayName).trim();
    }

    // Optional photoUrl
    const photoUrl =
      after.photoUrl && typeof after.photoUrl === "string"
        ? after.photoUrl
        : undefined;

    const publicData = {
      displayName: (displayName || "User").slice(0, 60),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (photoUrl) publicData.photoUrl = photoUrl;

    await pubRef.set(publicData, { merge: true });
  }
);

// Top of file with your other imports:
const { DateTime } = require("luxon");

// ---- Helpers for timezone day window + formatting ----
function todayWindowInTz(tz) {
  const now = DateTime.now().setZone(tz || "UTC");
  const start = now.startOf("day");
  const end = start.plus({ days: 1 });
  return {
    start: start.toJSDate(),
    end: end.toJSDate(),
    todayKey: start.toFormat("yyyy-LL-dd"),
    now, // keep luxon object for hour/min
  };
}

async function sumStepsForUserDay(uid, start, end) {
  const snap = await db
    .collection("owners").doc(uid)
    .collection("walks")
    .where("endedAt", ">=", start)
    .where("endedAt", "<", end)
    .select("steps") // bandwidth-friendly
    .get();

  let steps = 0;
  snap.forEach(d => {
    const n = d.get("steps");
    if (typeof n === "number" && isFinite(n)) steps += n;
  });
  return steps;
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

function buildMessage(steps) {
  if (steps > 0) {
    return `🐶💥 Woohoo! You and your pup crushed ${steps.toLocaleString()} steps today! 🐾 Keep the zoomies going!`;
  }
  // Upbeat prompt when there were no walks today
  return "🐾 You haven’t taken a walk yet today — quick lap time! Even 10 minutes counts. Let’s go! 🐕💨";
}

// ---- Scheduled sender: every 5 min; deliver at ~9:00–9:09pm local time ----
exports.sendDailyStepsRecap = onSchedule(
  { schedule: "every 5 minutes", timeZone: "UTC" },
  async () => {
    // Get all owners who can receive pushes and opted in
    const ownersSnap = await db.collection("owners")
      .where("fcmToken", "!=", null)           // token present
      .get();

    const owners = ownersSnap.docs.filter(d => {
      const data = d.data() || {};
      // default ON unless explicitly false
      return data.dailyStepsOptIn !== false && typeof data.fcmToken === "string" && data.fcmToken.trim();
    });

    // Process in small parallel chunks
    const chunkSize = 50;
    for (let i = 0; i < owners.length; i += chunkSize) {
      const chunk = owners.slice(i, i + chunkSize);
      await Promise.all(chunk.map(async (doc) => {
        const uid = doc.id;
        const data = doc.data() || {};
        const tz = typeof data.tz === "string" && data.tz ? data.tz : "UTC";
        const token = data.fcmToken;

        // Determine local time window for this user
        let win = todayWindowInTz(tz);
        if (!win.now.isValid) {
          win = todayWindowInTz("UTC");
        }

        // Only send between 21:00–21:09 local time, and only once per day
        if (win.now.hour !== 21 || win.now.minute >= 10) return;
        if (await alreadySentToday(uid, win.todayKey)) return;

        // Sum today's steps from walks
        const steps = await sumStepsForUserDay(uid, win.start, win.end);

        // Build and send notification
        const body = buildMessage(steps);
        try {
          await getMessaging().send({
            token,
            notification: {
              title: "🎉 Daily Dog Walk Recap",
              body,
            },
            data: {
              type: "daily_steps",
              day: win.todayKey,
              steps: String(steps),
              click_action: "FLUTTER_NOTIFICATION_CLICK",
            },
            android: {
              notification: {
                channelId: "daily_reminders", // create this channel in-app for nicer behavior
                priority: "HIGH",
              },
            },
            apns: {
              payload: {
                aps: {
                  sound: "default",
                  badge: 1,
                },
              },
            },
          });
          await markSent(uid, win.todayKey, tz);
        } catch (e) {
          console.error("Failed sending daily steps to", uid, e);
          // Don't mark as sent on failure
        }
      }));
    }
    return null;
  }
);

exports.notifyParkChat = onDocumentCreated(
  "parks/{parkId}/chat/{messageId}",
  async (event) => {
    const parkId = event.params.parkId;

    // 🔧 Use defensive checks instead of optional chaining / ??
    const msg = (event.data && typeof event.data.data === "function")
      ? event.data.data()
      : {};

    const senderId = msg.senderId || "someone";
    const text = (msg.text || "").toString().slice(0, 120);
    if (!text) return;

    const topic = `park_chat_${parkId}`;
    await getMessaging().send({
      topic,
      notification: { title: "New park chat message", body: text },
      data: {
        parkId,
        senderId: String(senderId),
        messageId: event.params.messageId,
      },
      android: { priority: "high" },
      apns: { payload: { aps: { sound: "default" } } },
    });
  }
);