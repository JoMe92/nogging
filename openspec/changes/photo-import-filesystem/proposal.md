# Photo import from the local filesystem

## Why

Users need to import image files through the application UI and immediately
see the imported images in the image strip.

## What changes

- Add a user-triggered filesystem image picker.
- Persist accepted imports through the application's image-import boundary.
- Refresh the image strip after a successful import.

## Out of scope

Cloud import, background bulk import, editing and deletion.
