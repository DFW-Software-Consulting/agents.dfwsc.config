---
description: "Remove AI-generated code slop from diff against main branch"
---
# Remove AI Code Slop

Check the diff against main, and remove all AI generated slop introduced in this branch.

This includes:
- Extra comments that a human wouldn't add or is inconsistent with the rest of the file
- Extra defensive checks or try/catch blocks that are abnormal for that area of the codebase (especially if called by trusted / validated codepaths)
- Casts to `any` to get around type issues
- Any other style that is inconsistent with the file

## Steps

1. **Get the diff:**
   ```
   git diff main...HEAD
   ```

2. **For each changed file:**
   - Read the FULL file to understand existing style and patterns
   - Identify AI slop in the changed regions:
     - Verbose comments that don't match the file's comment style
     - Unnecessary try/catch blocks where similar code doesn't have them
     - Defensive validation for already-validated inputs
     - `as any` or `any` type casts
     - Over-explaining variable names inconsistent with file naming
   - Use Edit to remove the slop

3. **Summary:**
   Report at the end with only a 1-3 sentence summary of what you changed
