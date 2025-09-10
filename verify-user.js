// verify-user.js
const admin = require("firebase-admin");

// If running locally, set GOOGLE_APPLICATION_CREDENTIALS to your service account JSON
// setx GOOGLE_APPLICATION_CREDENTIALS "C:\path\to\service-account.json"  (Windows PowerShell)
// or process.env.GOOGLE_APPLICATION_CREDENTIALS = "C:\\path\\to\\service-account.json";

admin.initializeApp({
  // If running in Cloud Functions or on GCP, default creds are fine and you can omit this
  credential: admin.credential.applicationDefault(),
});

// Replace with the user's UID
const UID = "ne0jWiYYLTPJpKhiUzNo929Fx1c2";

admin.auth().updateUser(UID, { emailVerified: true })
  .then(u => {
    console.log(`Marked ${u.uid} as emailVerified=true`);
    process.exit(0);
  })
  .catch(err => {
    console.error(err);
    process.exit(1);
  });
