# Agents Developer Guide

This document captures the project context, architecture, and coding style guidelines for the Legnick baseline economy simulation project. If you are an AI agent or a developer working on this codebase, you **must** adhere to these rules.

---

## 1. Project Context & Architecture

This project is an agent-based macroeconomic simulation written in Zig, implementing the **Legnick baseline economy model** (derived from Legnick 2013, *"A baseline agent-based model of a macroeconomic system"*). 

The economy consists of two primary types of agents interacting in a decentralized market:
- **Households**: Seek employment at firms, receive wages, plan daily consumption budgets, and purchase goods from preferred suppliers. They blackmark suppliers that fail to satisfy their demand.
- **Firms**: Hire households, produce goods using labor, set prices based on inventory levels, adjust wages based on vacancy filling success, and pay wages.

### Key Primitives ([core.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/core.zig))
- `Id = usize`: Represents the unique index of an agent in the simulation arrays.
- `Currency = u64`: Represents money in **cents** to avoid floating-point rounding errors in transactions.
- `GoodsAmount = u64`: Represents the discrete quantity of goods.

### Directory Structure
- [src/main.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/main.zig): Entry point of the simulation. Sets up the allocators and runs the model steps loop.
- [src/legnick/root.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/root.zig): Core package exports.
- [src/legnick/model.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/model.zig): The orchestrator struct `Model` that manages the simulation time steps and agents.
- [src/legnick/firms.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/firms.zig): Contains `Firm` structure, constants, and the `Firms` collection manager.
- [src/legnick/households.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/households.zig): Contains `Household` structure, constants, and the `Households` collection manager.
- [src/legnick/core.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/core.zig): Shared types, parameters, logging utilities, and helper functions.

---

## 2. Data-Oriented Design (SoA)

The project leverages a **Structure of Arrays (SoA)** layout using `std.MultiArrayList` rather than an Array of Structs (AoS). This optimizes CPU cache utilization during agent iterations.

### MultiArrayList Containers
`Firms` and `Households` act as collection wrappers:
```zig
pub const Table = std.MultiArrayList(Firm);
pub const Slice = Table.Slice;
```

### Accessing & Mutating Data
Helper functions should operate on `*const Slice` (or `*const HouseholdsSlice`) rather than the wrapper structs directly. This decouples logic from allocation/deallocation tasks.

- **Read-only access**: Access fields using `slice.items(.field)[index]`.
- **In-place mutation**: Get a pointer to the field inside the MultiArrayList columns:
  ```zig
  const wage_rate = &firms.items(.wage_rate)[index];
  wage_rate.* = new_wage;
  ```

---

## 3. House Style Rules

### 3.1 Memory Management
We practice **explicit allocation**. No hidden allocations are allowed.
- Functions that allocate memory must accept an `Allocator` parameter.
- **Double Arena Pattern**: The main executable uses two arena allocators:
  - `init_arena`: Lifetime of initialization, deallocated at shutdown.
  - `step_arena`: Reset at the end of each simulation step (`_ = step_arena.reset(.retain_capacity)`).
- When writing functions that require scratchpad memory (e.g., shuffling orders or accumulating indexes), take a temporary `arena: Allocator` and allocate there.

#### Code Example: Memory Allocation
```zig
// DO: Pass explicit allocator and use defer for cleanups
pub fn doSomething(arena: Allocator, slice: *const Slice) ![]Id {
    var list = try arena.alloc(Id, slice.len);
    // ...
    return list;
}

// DON'T: Hide allocations or use global/hidden allocators
pub fn doSomethingBad(slice: *const Slice) []Id {
    // Unclear where memory comes from or how it is freed
    var list = std.heap.page_allocator.alloc(Id, slice.len) catch unreachable;
    return list;
}
```

### 3.2 Naming Conventions
- **Structs & Types**: `PascalCase` (e.g., `Model`, `FirmConfig`, `Households`).
- **Variables & Fields**: `snake_case` (e.g., `init_arena`, `avg_wage`, `has_open_position`).
- **Collection/Module Functions**: `camelCase` (e.g., `onMonthStart`, `manageWorkforce`, `isUnhappyAtWork`).
- **Helper Functions Inside Raw Entity Structs**: `snake_case` (e.g., `add_sampled_firm` in `Household`).
- **Scientific Parameters**: Lowercase letters (and words) matching scientific paper definitions (e.g., `gamma`, `delta`, `theta`, `psi_price`).

#### Code Example: Naming Style
```zig
// DO: Correct PascalCase for structs, snake_case for fields/variables, camelCase for functions
pub const EconomyModel = struct {
    poverty_level: f32 = 1.0,

    pub fn runSimulationStep(self: *EconomyModel, step_index: usize) void {
        const step_coefficient = @as(f32, @floatFromInt(step_index));
        _ = step_coefficient;
    }
};

// DON'T: Mix casing formats arbitrarily
pub const economy_model = struct { // Should be PascalCase
    povertyLevel: f32 = 1.0,        // Should be snake_case

    pub fn RunSimulation_Step(self: *economy_model, StepIndex: usize) void { // Should be camelCase
        const stepCoefficient = @as(f32, @floatFromInt(StepIndex));
    }
};
```

### 3.3 Numeric Type Safety & Conversions
Zig requires strict type safety. There are no implicit type coercions between integers and floats.
- Perform explicit casts using `@floatFromInt` and `@intFromFloat`.
- Always wrap division properly: use `@divTrunc`, `@divFloor`, or `@divExact` for integers, and standard `/` for floats.
- Clamp values when converting back to ensure they stay within bounds.

#### Code Example: Casts and Math
```zig
// DO: Explicitly cast and round prior to converting float to int
const current_price_f32: f32 = @floatFromInt(firms.items(.goods_price)[id]);
const adjusted_price_f32 = current_price_f32 * 1.05;
firms.items(.goods_price)[id] = @intFromFloat(std.math.round(adjusted_price_f32));

// DON'T: Try to implicitly mix types or divide integers with '/'
const price = firms.items(.goods_price)[id];
const invalid = price * 1.05; // Compile error: incompatible types
const bad_div = price / 2;    // Compile error: use @divTrunc or @divFloor
```

### 3.4 Error Handling
- Use **explicit error sets** in function signatures where possible rather than general `anyerror`.
- Error names must be `PascalCase`.
- Use `catch` for local error fallback or propagation, and `std.debug.panic` only for fatal invariants/corrupted simulation states.

#### Code Example: Errors
```zig
// DO: Explicit error sets
pub const JobError = error{
    AlreadyEmployed,
    EmployerNotFound,
};

pub fn hire(employer_id: Id) JobError!void {
    if (employer_id == 0) return error.AlreadyEmployed;
}

// DON'T: Use anyerror blindly when the error set is small and known
pub fn fire(employer_id: Id) anyerror!void {
    // ...
}
```

### 3.5 Code Comments & Documentation
- Document files/modules using `//!` at the beginning of the file.
- Document structs, fields, and public functions using `///`.
- Write inline comments using `//` to explain simulation logic (especially equations or scientific logic referenced from the original Legnick paper).

---

## 4. Best Practices for Modifying the Simulation

When adding new mechanics or parameters to the simulation:
1. **Extend Configurations**: Add new configuration parameters to `FirmConfig` ([firms.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/firms.zig#L16)) or `HouseholdConfig` ([households.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/households.zig#L15)).
2. **Keep Helper Functions Pure**: Helper functions in `firms.zig` and `households.zig` should only take slices and indexes. Avoid passing the entire `Model` or collection wrappers to small helpers.
3. **Respect the Time scale**: The simulation steps on a daily basis. Months have a fixed length (default `28` days). Keep track of `is_month_start` and `is_month_end` in [model.zig](file:///C:/Users/Axel/workspace/axelmagn/econ-legnick/src/legnick/model.zig#L36) to schedule monthly updates (like wage adjustments, reservation wage decay, workforce adjustments).
