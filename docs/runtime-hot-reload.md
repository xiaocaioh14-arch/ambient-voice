# Runtime Configuration Hot Reload

## Design
- ~/.we/runtime-config.json monitored via DispatchSource file watcher
- Changes applied without app restart
- Published via NotificationCenter

## Supported Runtime Config
- Polish enabled/disabled toggle
- Log level changes
- Feature flags

## Implementation
RuntimeConfig uses DispatchSource.makeFileSystemObjectSource to watch for file changes.
On change: re-read JSON, validate, publish via notification.
