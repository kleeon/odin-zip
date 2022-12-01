# odin-zip

Zip file reading/writing package for Odin programming language. Supports streaming and zip64.

# Example

```odin
package main

import "core:fmt"
import "core:io"

import "zip"

main :: proc() {
    archive, err := zip.load_from_file("test.zip")
    defer zip.close_archive(&archive)

    buf := make([dynamic]byte, 64) // Allocate small buffer to demonstrate streaming
    defer delete(buf)

    for _, i in archive.files {
      f := &archive.files[i]
      fmt.println("File name:", f.name)

      r, _ := zip.open_file_reader(f)
      defer zip.close_file_reader(f)

      fmt.print("File contents: ")
      for { // Read contents of the file
        n, err := io.read(r, buf[:])

        fmt.print(string(buf[:n]))
        if err != nil { // Break on EOF
          break
        }
      }

      fmt.println()
      fmt.println("Last modified:", f.lastModifiedDateTime)
      fmt.println("----------------------------")
    }
}
```
