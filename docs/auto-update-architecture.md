# PaperRss macOS Auto Update Architecture

## Status

Draft

## Decision

PaperRss will adopt a production-grade macOS auto update architecture based on Sparkle 2.

The current custom Release API update checker will be deprecated and removed.

The target architecture follows mature macOS independent applications:

- NetNewsWire style distribution model
- Codex style update experience

---

# 1. Goals

Provide a native macOS update experience:

```
Open PaperRss
        ↓
Background update check
        ↓
Download update silently
        ↓
Restart to Update
        ↓
New version launches
```

Users should not need to:

- Download DMG repeatedly
- Replace applications manually
- Execute xattr commands
- Manage update files

---

# 2. Final Architecture

```
PaperRss.app

    |
    v

Sparkle 2 Framework

    |
    v

appcast.xml

    |
    v

PaperRss-x.x.x.zip

    |
    v

GitHub Release / CDN
```

Sparkle becomes the only update mechanism.

---

# 3. Migration Decision

Remove the custom updater:

```
GitHub Release API
        ↓
Version comparison
        ↓
Manual download
        ↓
Application replacement
```

Deprecated components:

- Release checker
- Custom download manager
- Manual installer logic
- GitHub API polling

Sparkle owns:

- Version checking
- Download management
- Update verification
- Installation
- Restart flow

---

# 4. Sparkle Integration

Dependency:

```
https://github.com/sparkle-project/Sparkle
```

Use Sparkle 2.x.

Recommended location:

```
Infrastructure/
    Update/
        SparkleUpdater.swift
```

Responsibilities:

- Initialize updater
- Trigger update checks
- Provide update status
- Connect with PaperRss UI

---

# 5. Update Feed

Sparkle uses appcast.xml.

Example:

```
https://paperrss.app/appcast.xml
```

Info.plist:

```
SUFeedURL
```

points to the update feed.

---

# 6. Release Workflow

Every release:

```
Update version
        ↓
Build Archive
        ↓
Export PaperRss.app
        ↓
Create zip artifact
        ↓
Generate Sparkle signature
        ↓
Generate appcast.xml
        ↓
Upload Release
```

GitHub Release becomes file hosting only.

Sparkle becomes the update system.

---

# 7. Security

Use Sparkle EdDSA signing.

Update flow:

```
Build artifact
        ↓
Sparkle signature
        ↓
appcast.xml
        ↓
Client verification
        ↓
Install
```

---

# 8. Future Apple Distribution

Before public release add:

```
Developer ID Application Certificate
        ↓
Code Signing
        ↓
Hardened Runtime
        ↓
Apple Notarization
        ↓
Staple Ticket
        ↓
Sparkle Release
```

Final production pipeline:

```
Build
 ↓
Developer ID Sign
 ↓
Apple Notarize
 ↓
Sparkle Sign
 ↓
Generate appcast
 ↓
Release
```

---

# 9. Implementation Checklist

- [ ] Add Sparkle 2 dependency
- [ ] Remove old release checker
- [ ] Implement Sparkle updater manager
- [ ] Add update settings UI
- [ ] Configure appcast.xml
- [ ] Setup Sparkle signing key
- [ ] Test background download
- [ ] Test restart update flow
- [ ] Verify user data persistence
- [ ] Document release process

---

# Final Decision

PaperRss will not maintain a custom updater.

The permanent architecture is:

```
Sparkle 2
+
appcast.xml
+
EdDSA signing
+
GitHub Release hosting
+
Future Apple Notarization
```
