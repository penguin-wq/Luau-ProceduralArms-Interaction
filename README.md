# Luau Procedural Arms Interaction

A client-side Roblox module that gives the player's character two physics-driven, procedurally animated arms. Left and right mouse buttons raise the matching arm, and a raised arm grabs the nearest loose part and carries it around using physics constraints.

There are no animation assets. Arm motion comes from a spring simulation fed by movement, camera, and falling state, so the arms sway, drag, and flail in response to how the player moves.

## Features

- **Independent arms.** `MouseButton1` controls the left arm and `MouseButton2` controls the right arm.
- **Spring-driven pose.** Each arm's rotation is a damped spring chasing a target angle, so transitions between idle, raised, and falling poses feel weighty rather than snapped.
- **Movement response.** The arms bob while idle, bob faster while moving, lag behind velocity on all three axes, and swing with acceleration and deceleration.
- **Raise and release kicks.** Raising or releasing an arm adds a randomized impulse to the spring for a slightly different feel every time.
- **Fall reaction.** Once downward velocity passes a threshold, both unraised arms blend toward a flailing pose with extra wobble.
- **Physics grabbing.** A raised arm grabs the nearest valid part with `AlignPosition` and `AlignOrientation`, with force and torque scaled by the part's mass.
- **Opt-out tag.** Parts tagged `NonInteractable` can never be grabbed.
- **Optional cursor.** A `BillboardGui` on each grip attachment can show a cursor image while the arm is raised.

## Files

| File              | Purpose                                                              |
| ----------------- | -------------------------------------------------------------------- |
| `Interaction.luau` | The module: arm rig, spring animation, grab logic, input handling   |
| `Constant.luau`    | All tuning values, poses, and asset IDs                             |

`Start()` connects the input handlers, hooks `CharacterAdded`, and sets up the current character if one already exists. Call it once.

## How It Works

### Arm rig

On every character spawn, the module:

1. Destroys the `Motor6D`, `Weld`, and `WeldConstraint` joints attached to each arm.
2. Sets each arm to `Anchored = true` and `CanCollide = false`.
3. Creates a cursor `BillboardGui` on each grip attachment.
4. Connects a `RenderStepped` loop that places the arms every frame.

Each frame, a shoulder `CFrame` is built from the torso position and the camera's rotation, then offset by a per-arm pivot and roll. The spring angles are applied on top, and the arm is shifted by half its length so it rotates about the shoulder.

### Animation target

The target angle for each arm is the sum of several layers:

| Layer                | Active when        | Source                                     |
| -------------------- | ------------------ | ------------------------------------------ |
| Base pose            | Always             | Idle, raised, or fall angles               |
| Bob                  | Always             | Sine and cosine of time, faster when moving |
| Velocity drag        | Always             | Local velocity on X, Y, and Z, clamped     |
| Acceleration inertia | Always             | Change in local velocity per second, clamped |
| Raise wobble         | Arm is raised      | Phase-shifted sine waves                   |
| Fall wobble          | Arm is not raised  | Phase-shifted sine waves scaled by fall intensity |

The fall intensity ramps from 0 to 1 as vertical velocity drops below `FALL_VELOCITY`, and eases toward its target at `FALL_BLEND_SPEED`. It blends the unraised base pose toward the fall pose.

The spring then steps toward the target angle:

```lua
local accel = (target - current) * SPRING_STIFFNESS - velocity * SPRING_DAMPING
velocity = velocity + accel * dt
current = current + velocity * dt
```

### Grabbing

While an arm is raised and holding nothing, `try_grab` runs every frame:

1. `workspace:GetPartBoundsInRadius` finds parts within `GRAB_RADIUS` of the grip attachment, excluding the character.
2. The nearest part that is a `BasePart`, is unanchored, and lacks the `NonInteractable` tag is chosen.
3. A `GrabAttachment` is created on that part at the grip's current relative position.
4. An `AlignPosition` and an `AlignOrientation` pull the part's attachment toward the grip. `MaxForce` is `sqrt(AssemblyMass) * GRAB_FORCE_PER_MASS` and `MaxTorque` is `AssemblyMass * GRAB_TORQUE_PER_MASS`.

Releasing the mouse button destroys the constraints and the attachment, and the part falls under normal physics.

## Configuration

Everything is tuned in `Constant.luau`.

### Poses

| Constant                                  | Description                                  |
| ----------------------------------------- | -------------------------------------------- |
| `LEFT_IDLE_ANGLES`, `RIGHT_IDLE_ANGLES`   | Resting arm rotation                         |
| `LEFT_RAISE_ANGLES`, `RIGHT_RAISE_ANGLES` | Rotation while the mouse button is held      |
| `LEFT_FALL_ANGLES`, `RIGHT_FALL_ANGLES`   | Rotation while falling                       |

### Spring

| Constant           | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| `SPRING_STIFFNESS` | How hard the arm is pulled toward its target                 |
| `SPRING_DAMPING`   | How quickly oscillation dies out                             |
| `RAISE_KICK_STRENGTH`   | Random impulse, in degrees, when an arm is raised       |
| `RELEASE_KICK_STRENGTH` | Random impulse, in degrees, when an arm is released     |

### Motion

| Constant                                             | Description                                      |
| ---------------------------------------------------- | ------------------------------------------------ |
| `IDLE_BOB_SPEED`, `IDLE_BOB_AMOUNT`                  | Bob frequency and amplitude while standing still |
| `MOVE_BOB_SPEED`, `MOVE_BOB_AMOUNT`                  | Bob frequency and amplitude while moving         |
| `FORWARD_DRAG_SCALE`, `STRAFE_DRAG_SCALE`, `VERTICAL_DRAG_SCALE` | How strongly velocity pushes the arms |
| `DRAG_MAX`                                           | Clamp on velocity drag, in degrees               |
| `ACCEL_DRAG_SCALE`, `ACCEL_DRAG_MAX`                 | Strength and clamp of acceleration inertia       |
| `RAISE_WOBBLE_SPEED`, `RAISE_WOBBLE_AMOUNT`          | Wobble while an arm is raised                    |

### Falling

| Constant                                   | Description                                         |
| ------------------------------------------ | --------------------------------------------------- |
| `FALL_VELOCITY`                            | Vertical velocity at which the fall pose begins     |
| `FALL_BLEND_SPEED`                         | How fast the fall pose fades in and out             |
| `FALL_WOBBLE_SPEED`, `FALL_WOBBLE_AMOUNT`  | Flailing frequency and amplitude                    |

### Grabbing

| Constant                | Description                                              |
| ----------------------- | -------------------------------------------------------- |
| `GRAB_RADIUS`           | Search radius around the grip attachment, in studs       |
| `GRAB_RESPONSIVENESS`   | Responsiveness of both align constraints                 |
| `GRAB_FORCE_PER_MASS`   | Multiplier for `AlignPosition` force                     |
| `GRAB_TORQUE_PER_MASS`  | Multiplier for `AlignOrientation` torque                 |
| `NON_INTERACTABLE_TAG`  | `CollectionService` tag that blocks grabbing             |

### Cursor

| Constant                                                  | Description                                |
| --------------------------------------------------------- | ------------------------------------------ |
| `CURSOR_ENABLED`                                          | Show the cursor while an arm is raised     |
| `CURSOR_SIZE`                                             | Size of the `BillboardGui`                 |
| `GRAB_LEFT_CURSOR_ASSET_ID`, `GRAB_RIGHT_CURSOR_ASSET_ID` | Cursor images                              |

## Usage Tips

- Tag any part you don't want players to pick up:

```lua
local collectionService = game:GetService("CollectionService")

collectionService:AddTag(workspace.Door, "NonInteractable")
```

- `GRAB_RADIUS` is `0.1` studs, so a part must be almost touching the grip attachment to be grabbed. Increase it for a more forgiving reach.
- To make the arms looser and floppier, lower `SPRING_STIFFNESS` or `SPRING_DAMPING`. To make them snappier, raise them.

## Limitations

- **Local only.** Arms are positioned on the client, so other players do not see them move.
- **Network ownership.** Grab constraints are created on the client, so physics on a grabbed part only behaves correctly when that client owns the part.
- **Unused constants.** `IDLE_TORQUE`, `IDLE_RESPONSIVENESS`, `RAISE_TORQUE`, and `RAISE_RESPONSIVENESS` are defined in `Constant.luau` but not read by the module. The hover cursor IDs are commented out.
- **R6 only.** Arm names, pivot offsets, and the torso lookup assume an R6 rig.
