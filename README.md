# Romal's ECS

**A lightweight Entity Component System for Luau**

Romal's ECS is a strictly typed module for scripting systems that make use of entities and components. Entities are tracked via recycled integer IDs, components are stored as flat primitive values behind reactive proxies, and system queries filter entities using fast bitwise operations, keeping your game greatly optimized.

## Features

- **Performance**: Entity queries use `bit32` bitmask operations to filter by component composition in a single pass, ID and bit positions are recycled to keep memory usage flat, and bulk entity creation amortizes setup cost across many entities at once
- **Simplicity**: Components are flat primitive values — no nested tables, no ambiguous shapes. Each entity is just an integer ID, and all operations take that ID directly
- **Ease of Use**: Components fire a `ComponentChanged` event automatically on any write, entities contain `ComponentAdded` and `ComponentRemoved` signals
- **Strict Typing**: Built with `--!strict` throughout, with exported types for `Component<T>` and `Entity<T>`
- **Zero Dependencies**: Single-module with no external packages required

## Installation
1. Download the latest release
2. Place the module in `ServerScriptService` or any folder under that Service
3. Require the module in your server sided scripts

