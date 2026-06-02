# BAM - Backup Android Media

Here a little PowerShell script that backs up media from an Android phone over `adb`.

Requirement: `adb` must be installed on the PC and available in `PATH`.

## Install adb on Windows

1. Download Android SDK Platform Tools from Google:
	https://developer.android.com/tools/releases/platform-tools
2. Extract the zip file, for example into `C:\Android\platform-tools`
3. Add that folder to your `PATH`
4. Open a new PowerShell window and verify:

```powershell
adb version
```

If the command prints the adb version, the script can use it.

What it does:

- Scans `/sdcard/DCIM`, `/sdcard/Pictures`, and `/sdcard/Movies`
- Copies supported photo and video files into `<destination>/<device>/...`
- Preserves the folder structure under each source folder
- Skips files already backed up when the local file size matches the phone file size
- Optionally deletes files from the phone after a verified copy

## Usage

Preview what would happen:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups' -DryRun
```

Copy only:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups'
```

Copy, then delete verified files from the phone:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups' -DeleteAfterCopy
```

Use either a relative or absolute destination root:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot 'D:\PhoneBackups'
```

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups'
```

Filter by filename substring:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups' -FilenameContains '20251122' -DryRun
```

Filter by filename prefix:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups' -FilenameStartsWith '20251122_' -DryRun
```

Print only the header and summary, without one line per file:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups' -FilenameStartsWith '20251122_' -DryRun -SummaryOnly
```

If you have more than one device connected, pass the serial shown by `adb devices`:

```powershell
.\Move-AndroidMedia.ps1 -DestinationRoot '.\phone-backups' -Serial R5CY81EQTTF
```

## Notes

- Test with `-DryRun` first.
- Leave the phone unlocked while the transfer runs.
- Samsung camera media is usually under `/sdcard/DCIM/Camera`, which is already covered by `/sdcard/DCIM`.
- `-FilenameContains` matches only against the file name, not the full folder path, and it is case-insensitive.
- `-FilenameStartsWith` matches only against the file name, not the full folder path, and it is case-insensitive.
- `-SummaryOnly` suppresses per-file action lines and leaves the header and final summary.