# TealKit for macOS — Direct Download Version

If you are using TealKit on macOS, there are two versions available:

1. **Mac App Store Version**: Runs in the standard macOS App Sandbox. It is highly secure but cannot execute local terminal commands, Python environments, or Node.js tools on your machine.
2. **Direct Download Version**: Runs as a standard developer application with the sandbox disabled. 

> [!IMPORTANT]
> **Remark:** Use the direct download version if you would like to use local Python, Node.js, or custom CLI-based MCP servers (such as `uv`, `npm`, or `pip` installable tools).
> 
> *Note:* The direct download version is **not needed** if you use Headless Mode on macOS. This configuration is fully supported: run the sandboxed TealKit macOS UI and connect it to a TealKit headless Docker container running as a service on the same Mac. In this case, all local MCP servers are installed, executed, and maintained inside the Docker container rather than on the host system.

## Download Links

* **DMG Installer**: [Download TealKit Direct version (TealKit-macos-direct.dmg)](https://tealkit.dev/download/TealKit-macos-direct.dmg)

## Installation Instructions

1. Download the DMG from the link above.
2. Open the DMG and drag **TealKit** to your local **Applications** (Programme) folder. 
   > [!CAUTION]
   > **Do not run the app directly from the opened DMG window.** The DMG volume is read-only, which will cause Gatekeeper bypass methods and terminal commands to fail. You **must** copy the app to `/Applications` first.
3. Once copied to `/Applications`, close the DMG window and open Finder. Go to your **Applications** folder. macOS Gatekeeper will show a warning stating that Apple cannot verify the app for malware. You can bypass this using one of these three methods:

   * **Method A (Right-Click Open)**: Right-click (or Control-click) the **TealKit** application icon inside your `/Applications` directory, then click **Open**. A dialog will appear containing an explicit **Open** button next to Cancel. Click **Open** to run the app.
   * **Method B (System Settings)**: Open **System Settings** -> **Privacy & Security** (Datenschutz & Sicherheit), scroll down to the **Security** section, find the notice mentioning *TealKit was blocked*, and click **Open Anyway** (Dennoch öffnen).
   * **Method C (Terminal Command)**: Remove the quarantine attribute by running the following command in Terminal:
     ```bash
     xattr -cr /Applications/TealKit.app
     ```
