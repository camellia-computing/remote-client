# Camellia Remote MSI project

Use Visual Studio 2022 to compile this project.

This installer project is derived in part from
<https://github.com/MediaPortal/MediaPortal-2.git> and the imported RustDesk
installer sources documented in the repository provenance files.

## Steps

1. Run `python preprocess.py`, using `python preprocess.py -h` for the supported
   inputs. The distribution directory must already contain the named application
   executable. Product names, executable names, versions, and custom ARP metadata
   are validated before they are written into WiX sources.
2. Build the .sln solution.

Preprocessing is repeatable: generated marker sections are replaced rather than
appended, component identifiers are derived from stable product-relative paths,
and the product upgrade code remains stable across builds. Run preprocessing only
against a trusted build output because it executes that application to read its
build date when producing installer metadata.

Run `msiexec /i package.msi /l*v install.log` to record the log.

## Usage

1. Put the custom dialog bitmaps in "Resources" directory. The supported bitmaps are `['WixUIBannerBmp', 'WixUIDialogBmp', 'WixUIExclamationIco', 'WixUIInfoIco', 'WixUINewIco', 'WixUIUpIco']`.

## Knowledge

### properties

[wix-toolset-set-custom-action-run-only-on-uninstall](https://www.advancedinstaller.com/versus/wix-toolset/wix-toolset-set-custom-action-run-only-on-uninstall.html)

| Property Name | Install | Uninstall | Change | Repair | Upgrade |
| ------ | ------ | ------ | ------ | ------ | ------ |
| Installed | False | True | True | True | True |
| REINSTALL | False | False | False | True | False |
| UPGRADINGPRODUCTCODE | False | False | False | False | True |
| REMOVE | False | True | False | False | True |

## TODOs

1. Start menu. Uninstall
1. custom options
1. Custom client.
    1. firewall and tcp allow. Outgoing
    1. Show license ?
    1. Do create service. Outgoing.

## Refs

1. [windows-installer-portal](https://learn.microsoft.com/en-us/windows/win32/Msi/windows-installer-portal)
1. [wxs](https://wixtoolset.org/docs/schema/wxs/)
1. [wxs github](https://github.com/wixtoolset/wix)
