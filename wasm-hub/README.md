# WASM Hub

Web platform for uploading and sharing WebAssembly files.

## Run Locally

```bash
cd wasm-hub
npm install
npm run dev
```

Opens at `http://localhost:5173`

## Deploy to Firebase

```bash
npm run build
firebase login
firebase deploy
```

## Common Errors

| Error | Fix |
|-------|-----|
| Firebase config missing | Copy `.env.example` to `.env` and fill in your Firebase credentials |
| Permission denied | Make sure Firestore/Storage rules are deployed: `firebase deploy --only firestore:rules,storage:rules` |
| Index error | Click the link in the error to create the index in Firebase Console |
| Popup blocked on download | Allow popups for the site in your browser |
