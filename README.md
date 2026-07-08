# omininote

A Flutter stylus note-taking app with cloud sync support via Google Drive.

## Setup

### Google Drive Integration (Desktop & Android)

This app requires Google OAuth credentials for Drive sync on desktop and Android platforms.

1. **Get credentials from Google Cloud Console:**
   - Go to [Google Cloud Console](https://console.cloud.google.com/)
   - Create a new project or select an existing one
   - Enable the Google Drive API
   - Create an OAuth 2.0 Client ID (type: Desktop application)
   - Download the credentials JSON

2. **Set environment variables:**
   ```bash
   export GOOGLE_CLIENT_ID="your-client-id"
   export GOOGLE_CLIENT_SECRET="your-client-secret"
   ```

   Or pass them inline when running:
   ```bash
   GOOGLE_CLIENT_ID="..." GOOGLE_CLIENT_SECRET="..." flutter run
   ```

3. **See `.env.example`** for a template of required environment variables.

## Building & Running

```bash
flutter pub get          # Install dependencies
flutter run -d windows   # Run on desktop (with env vars set)
flutter run -d android   # Run on Android
```

See `CLAUDE.md` for full architecture and feature details.

## Resources

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)
