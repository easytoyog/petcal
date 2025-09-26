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
