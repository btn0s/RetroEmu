# LibretroFrontend for PPSSPP

## Goal
Implement a minimal frontend for the libretro PPSSPP core using Swift, enabling basic PSP game emulation through a simple iOS interface.

## Structure
- `LibretroFrontend.swift`: Core implementation of the libretro frontend
- `RetroBBApp.swift`: SwiftUI app entry point
- `ContentView.swift`: Main SwiftUI view
- `ViewController.swift`: UIKit view controller for handling the emulator view
- `LibretroWrapper.m` and `LibretroWrapper.h`: Objective-C wrapper for C functions
- `libretro.h`: C header defining the libretro API
- `module.modulemap`: Module map for exposing C headers to Swift

## Features
- Loading and initialization of the PPSSPP libretro core
- Basic game ROM loading and execution
- Audio output
- Video rendering
- Input handling
- Simple iOS user interface for interaction

## Relevant Documentation

### LibretroFrontend.swift
This file contains the main implementation of the libretro frontend. Key functions include:

- `init()`: Initializes the frontend and loads the core
- `loadGame(at:)`: Loads a game ROM
- `run()`: Runs the emulation loop
- `handleAudioCallback(_:)`: Processes audio data
- `handleVideoRefresh(_:width:height:pitch:)`: Handles video frame updates

### RetroBBApp.swift
The main entry point for the SwiftUI app. It sets up the app structure and initializes the main view.

### ContentView.swift
The main SwiftUI view that presents the user interface, including the emulator view and controls.

### ViewController.swift
A UIKit view controller that manages the emulator view, handling rendering and input.

### LibretroWrapper.m and LibretroWrapper.h
These files provide an Objective-C wrapper around the C functions from the libretro API, making them accessible to Swift code.

### libretro.h
The C header file that defines the libretro API. This file specifies the interface that the frontend must implement to communicate with the libretro core.

For detailed information on the libretro API, refer to the [Libretro Documentation](https://docs.libretro.com/).