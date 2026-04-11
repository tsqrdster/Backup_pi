# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added .config option "UNMOUNT_CUSTOM_MOUNTS_PRIOR_TO_BACKUP" which will scan system for custom mounts, either from the fstab or manually added, then temporarily unmount those found prior to running the backup, then re-mount them after the backup completes.
- Added cleanup function and trap to perform necessary actions to restore system (mounts and services) when the script exits (successful or halted execution...)

### Changed

- Changed the "Shebang" so it will use the BASH version the system has as it's default.
- Changed README.md to include new information on the unmount option and further information on prerequisites and more details about scheduling the script in the Automation section.

### Fixed

- Added checks to skip messages if .conf is not set to stop any services or containers.

### Removed

## [1.0.1] - 2026-03-23

### Added

### Changed

### Fixed

- Rotation of Backups and logs not matching due to quotes around PATTERN variable which included the asterisk. Now the asterisk is not included in the PATTERN variable and the list of matching backups or logs is correct again.

### Removed

## [1.0.0] - 2026-03-23

### Added

- First release which includes all the original features.

### Changed

### Fixed

### Removed

## [0.0.01] - [0.0.87] - 2026-03-22 [YANKED]