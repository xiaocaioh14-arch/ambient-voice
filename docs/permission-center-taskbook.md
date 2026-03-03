# Permission Center Design

## Required Permissions
1. Accessibility - for AX text injection and global event monitoring
2. Microphone - for audio recording

## Implementation
- PermissionManager tracks status of each permission
- PermissionGuideController shows step-by-step guide
- Auto-detect permission changes via polling
- Guide shown on first launch or from menu bar

## Future
- Input Monitoring permission (if needed for key events)
- Screen Recording (if needed for future modules)
