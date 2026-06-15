# Preinstall Requirements - Local DB App

Use this file for OS packages or runtime binaries that must exist before Multidev runs dependency install or build.

```vps-requirements
{
  "apt": []
}
```

If the app needs Chromium, add `"chromium"` to the `apt` array.
Keep the list empty when no extra system packages are required.
