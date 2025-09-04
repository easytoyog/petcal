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

/* =========================
   Existing logic
   ========================= */

exports.notifyFriendCheckIn = onDocumentCreated(
  "parks/{parkId}/active_users/{userId}",
  async (event) => {
    const parkId = event.params.parkId;
    const userId = event.params.userId;
    const db = getFirestore();

    // Get all friends of this user
    const friendsSnap = await db
      .collection("friends")
      .doc(userId)
      .collection("userFriends")
      .get();

    for (const friendDoc of friendsSnap.docs) {
      const friendId = friendDoc.id;

      // Check if friend liked this park
      const likedParkDoc = await db
        .collection("owners")
        .doc(friendId)
        .collection("likedParks")
        .doc(parkId)
        .get();

      if (likedParkDoc.exists) {
        // Get friend's FCM token
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
            data: {
              parkId: parkId,
              friendId: userId,
            },
          });
        }
      }
    }
  }
);

exports.notifyFriendChatMessage = onDocumentCreated(
  "parks/{parkId}/chat/{messageId}",
  async (event) => {
    const parkId = event.params.parkId;
    const messageData = event.data.data();
    const senderId = messageData.senderId;
    const db = getFirestore();

    // Get all friends of the sender
    const friendsSnap = await db
      .collection("friends")
      .doc(senderId)
      .collection("userFriends")
      .get();

    for (const friendDoc of friendsSnap.docs) {
      const friendId = friendDoc.id;

      // Check if friend liked this park
      const likedParkDoc = await db
        .collection("owners")
        .doc(friendId)
        .collection("likedParks")
        .doc(parkId)
        .get();

      if (likedParkDoc.exists) {
        // Get friend's FCM token
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

// --- Auto checkout inactive users after ~1 hour (runs every 10 minutes) ---
exports.autoCheckoutInactiveUsers = onSchedule(
  { schedule: "every 10 minutes" },
  async () => {
    const db = admin.firestore();
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);

    const parksSnapshot = await db.collection("parks").get();
    for (const parkDoc of parksSnapshot.docs) {
      const activeUsersRef = parkDoc.ref.collection("active_users");
      const activeUsersSnapshot = await activeUsersRef.get();

      for (const userDoc of activeUsersSnapshot.docs) {
        const checkedInAt = userDoc.get("checkedInAt");
        if (checkedInAt && checkedInAt.toDate() < oneHourAgo) {
          // Delete the active user; the onDocumentDeleted trigger will decrement userCount
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

/**
 * setAdmin — Promote/demote by UID
 * Only callers who already have { admin: true } can use this.
 * App Check enforced to block non-legit clients.
 */
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
  await auth.revokeRefreshTokens(uid); // force token refresh

  return { ok: true, uid: uid, claims: merged };
});

/**
 * setAdminByEmail — Convenience: promote/demote by email
 * Same restrictions as above; returns the resolved uid for logging.
 */
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
   userCount triggers (tamper-proof)
   ========================= */

exports.onCheckInIncrementCount = onDocumentCreated(
  "parks/{parkId}/active_users/{uid}",
  async (event) => {
    const parkId = event.params.parkId;
    const db = admin.firestore();
    await db.collection("parks").doc(parkId).update({
      userCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
);

exports.onCheckOutDecrementCount = onDocumentDeleted(
  "parks/{parkId}/active_users/{uid}",
  async (event) => {
    const parkId = event.params.parkId;
    const db = admin.firestore();
    await db.collection("parks").doc(parkId).update({
      userCount: admin.firestore.FieldValue.increment(-1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
);

/* =========================
   Public profile mirror
   ========================= */

/**
 * Mirrors non-sensitive fields from owners/{uid} into public_profiles/{uid}.
 * If owners doc is deleted, remove the public profile.
 */
exports.mirrorOwnerToPublicProfile = onDocumentWritten(
  "owners/{uid}",
  async (event) => {
    const uid = event.params.uid;
    const db = admin.firestore();
    const pubRef = db.collection("public_profiles").doc(uid);

    // Get the "after" snapshot safely (no optional chaining)
    var afterSnap = event.data && event.data.after ? event.data.after : null;
    var after = null;
    if (afterSnap && typeof afterSnap.data === "function") {
      after = afterSnap.data();
    }

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
    var displayName = "";
    var firstName = after.firstName ? String(after.firstName).trim() : "";
    var lastName = after.lastName ? String(after.lastName).trim() : "";
    if (firstName && lastName) {
      displayName = (firstName + " " + lastName).trim();
    } else if (after.displayName) {
      displayName = String(after.displayName).trim();
    }

    // Optional photoUrl
    var photoUrl =
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
