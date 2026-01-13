# Group Task Tracker

A MacroQuest Lua script for tracking EverQuest task progress across all group members using DanNet.

## Features

- **Real-time Task Tracking**: See current task objective and progress for all group members
- **Invisible/IVU Status**: Monitor invis and invis vs undead status for the entire group
- **Group Actions**: Coordinate group-wide actions like:
  - Accept Task - All members accept the task window
  - Turn in Item - All members turn in items to targeted NPC
  - Hail - All members hail the target based on task progress
  - Inspect - All members inspect the target
  - Use Item - All members use a held item on the target
  - Loot All - All members loot nearby corpses
  - Pick Up - All members pick up nearby ground spawns

## Requirements

- MacroQuest with Lua support
- DanNet plugin running on all clients
- All characters must be in the same group

## Installation

1. Copy `GroupTaskTracker.lua` to your MacroQuest `lua` folder
2. Ensure DanNet is loaded on all clients

## Usage

```
/lua run GroupTaskTracker
```

### Commands

| Command | Description |
|---------|-------------|
| `/gqt` | Toggle the UI window |
| `/gqtstop` | Stop the script |
| `/gqtrefresh` | Refresh task data |
| `/gqtcleanup` | Clear all DanNet observers |

### How to Use

1. **Start the script** on all group members
2. **Select a task** from the Task Selection tab
3. **Monitor progress** - The main tab shows each member's current objective
4. **Use group actions** as needed:
   - Put item on cursor and target NPC, then click "Turn in Item"
   - Target NPC and click "Hail" for hail objectives
   - Target NPC and click "Inspect" for inspect objectives

### Tips

- The script uses DanNet persistent observers for efficient tracking
- Task progress updates automatically every few seconds
- Invis/IVU status updates every 200ms
- If a member shows incorrect progress, try clicking "Refresh"

## Technical Details

- Uses DanNet persistent observers for invis/ivu and task progress
- Task slot is found by matching Task.ID via transient queries
- Observers are created dynamically based on current objective
- When an objective completes, observers are dropped and recreated for the next step

## License

Free to use and modify.
