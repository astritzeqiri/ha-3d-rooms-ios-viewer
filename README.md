# 3D Rooms for Home

An iPhone and iPad viewer for the [3D Rooms Home Assistant integration](https://github.com/astritzeqiri/ha-3d-rooms). Choose a saved room, floor or house view and the app opens it full screen on each launch. On iOS 18 or later, you can also open the app from a Home Screen widget, the circular widget below the Lock Screen clock, a bottom Lock Screen control, or Control Center.

To protect your rooms on a shared device, open the view picker, tap the settings gear and turn on **Require Face ID**. Once enabled, the app locks whenever you leave it. You can use your device passcode as a fallback or turn the setting off in the same place.

In **Settings → Home Wi-Fi**, enter the exact Wi-Fi name and the internal URL of the same Home Assistant server. Allow precise location while using the app so iOS can share the network name. On other networks or when the name is unavailable, the app uses the address you signed in with. Use **Remove home network** to return to a single address.

## Build and run from source

1. On a Mac, install Xcode with the iOS SDK and an iPhone simulator runtime. Build 3 was compiled with Xcode 27.2. The viewer requires iOS or iPadOS 17 or later.
2. Clone the repository and open the included Xcode project.

   ```sh
   git clone https://github.com/astritzeqiri/ha-3d-rooms-ios-viewer.git
   cd ha-3d-rooms-ios-viewer
   open ThreeDRooms.xcodeproj
   ```

3. Select the **ThreeDRooms** scheme, choose an iPhone or iPad simulator, and press **Run** (⌘R).
4. To install your own build on a device, add your Apple account in Xcode settings. Under **Signing & Capabilities**, select your team for both **ThreeDRooms** and **RoomsControl**. If you use your own team, give the app a unique bundle ID and append `.RoomsControl` to that ID for the extension. Select your connected device and press **Run**.

For a command-line simulator build, run this from the repository root:

```sh
xcodebuild -project ThreeDRooms.xcodeproj -scheme ThreeDRooms \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

### Regenerate the project

The checked-in project is ready to build. If you change targets, signing settings or version numbers, make the same changes in `project.yml` so they survive regeneration. Install XcodeGen and run it from the repository root:

```sh
brew install xcodegen
xcodegen generate
```

### Create a TestFlight build

For the existing **3D Rooms for Home** listing, use its registered team and bundle IDs. Increment `CURRENT_PROJECT_VERSION` in `project.yml` and regenerate the project. Both targets inherit the build number. In Xcode, select the **ThreeDRooms** scheme and **Any iOS Device**, then **Product → Archive**. In Organizer, choose **Distribute App → App Store Connect → Upload**. Once Apple processes the build, select it for your tester group in App Store Connect. Uploading requires an Apple Developer Program team with access to the app record.

## Connect to your home

1. Install the 3D Rooms integration in Home Assistant and save a view in the room manager.
2. Open the iOS app, enter your Home Assistant address, and sign in on Home Assistant’s login page. Two-factor authentication works there. Your phone must be able to reach the address you enter.
3. Select the view you want to open at launch. To choose another, swipe in from the left edge or long-press the app icon and choose **Switch view**.

The app keeps the login in the device Keychain and loads the integration’s full-screen page at `/three_d_rooms_view/<view id>`. Updates to the room renderer arrive through the Home Assistant integration.

## Add a launcher

- **Below the Lock Screen clock:** Hold the Lock Screen, choose **Customize → Lock Screen**, tap the widget row beneath the clock, and choose **3D Rooms**.
- **Home Screen:** Hold an empty area, choose **Edit → Add Widget**, search for **3D Rooms**, and add the small launcher.
- **Control Center or a bottom Lock Screen control:** Open the controls gallery for that surface and choose **Open 3D Rooms**.
