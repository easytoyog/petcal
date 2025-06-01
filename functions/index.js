/* eslint-disable */

const admin = require("firebase-admin");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

admin.initializeApp();

exports.notifyFriendCheckIn = onDocumentCreated(
  "parks/{parkId}/active_users/{userId}",
  async (event) => {
    const { parkId, userId } = event.params;
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
        const ownerDoc = await db
          .collection("owners")
          .doc(friendId)
          .get();
        const fcmToken = ownerDoc.data().fcmToken;
        if (fcmToken) {
          // Send notification
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
    const { parkId, messageId } = event.params;
    const db = getFirestore();
    const messageData = event.data.data();
    const senderId = messageData.senderId;

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
        const ownerDoc = await db
          .collection("owners")
          .doc(friendId)
          .get();
        const fcmToken = ownerDoc.data().fcmToken;
        if (fcmToken) {
          // Send notification
          await getMessaging().send({
            token: fcmToken,
            notification: {
              title: "New message in your favorite park!",
              body: "Your friend posted in a park chat you like.",
            },
            data: {
              parkId: parkId,
              senderId: senderId,
              messageId: messageId,
            },
          });
        }
      }
    }
  }
);

// --- Auto checkout inactive users after 1 hour (v2 API) ---
exports.autoCheckoutInactiveUsers = onSchedule(
  { schedule: 'every 10 minutes' },
  async (event) => {
    const db = admin.firestore();
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);

    const parksSnapshot = await db.collection('parks').get();
    for (const parkDoc of parksSnapshot.docs) {
      const activeUsersRef = parkDoc.ref.collection('active_users');
      const activeUsersSnapshot = await activeUsersRef.get();

      for (const userDoc of activeUsersSnapshot.docs) {
        const checkedInAt = userDoc.get('checkedInAt');
        if (checkedInAt && checkedInAt.toDate() < oneHourAgo) {
          await userDoc.ref.delete();
          // Optionally decrement userCount
          await parkDoc.ref.update({
            userCount: admin.firestore.FieldValue.increment(-1),
          });
        }
      }
    }
    return null;
  }
);