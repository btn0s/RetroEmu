# RetroBB

## Overview
Libretro is a simple but powerful development interface that allows the creation of emulators, game engines, and media players to be easily ported to various platforms. It provides a common API that developers can use to create "cores" that can be run on any libretro-compatible frontend.

One of the most popular frontends for libretro is [RetroArch](https://www.retroarch.com/), which provides a comprehensive interface for running a wide variety of emulation cores. RetroArch is known for its extensive feature set, including support for multiple platforms, advanced configuration options, and a unified interface for managing and running games.

## Goal
The goal of this project is to implement a minimal frontend for the PPSSPP core using Swift. PPSSPP is a PSP emulator that has been ported to the libretro API, allowing it to be used as a core in libretro-compatible frontends. This frontend will enable basic PSP game emulation through a simple iOS interface, focusing on essential functionality without the extensive features of RetroArch.

## Structure
- `LibretroFrontend.swift`: Core implementation of the libretro frontend
- `RetroBBApp.swift`: SwiftUI app entry point
- `ContentView.swift`: Main SwiftUI view
- `libretro.h`: C header defining the libretro API

## Relevant Documentation

### Local Files

#### LibretroFrontend.swift
This file contains the main implementation of the libretro frontend.

#### RetroBBApp.swift
The main entry point for the SwiftUI app. It sets up the app structure and initializes the main view.

#### ContentView.swift
The main SwiftUI view that presents the user interface, including the emulator view and controls.

#### libretro.h
The C header file that defines the libretro API. This file specifies the interface that the frontend must implement to communicate with the libretro core.

#### ppsspp_libretro.dylib
This is the dynamic library that contains the PPSSPP core implementation. It is used to run the emulator and provide the necessary functionality to the frontend.
The source code for the this core is located in the [`Lib/ppsspp-master`](https://github.com/Backbone-Labs/RetroBB-iOS/tree/main/Lib/ppsspp-master) directory.

### Web Resources

- [Libretro Documentation](https://docs.libretro.com/).
- [Libretro Frontend Development](https://docs.libretro.com/development/frontends/).
- [Retroarch iOS Reference](https://docs.libretro.com/development/retroarch/compilation/ios/).
- [PPSSPP GitHub](https://github.com/hrydgard/ppsspp).
