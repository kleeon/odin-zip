package zip

import "core:fmt"
import "core:io"
import "core:os/os2"
import zip "."

main :: proc() {
  fmt.println("Zip reading test:")
  {
    archive, err := zip.load_from_file("test.zip")
    defer zip.close_archive(&archive)

    buf := make([dynamic]byte, 64)
    defer delete(buf)

    for _, i in archive.files {
      f := &archive.files[i]
      fmt.println("File name:", f.name)

      r, _ := zip.open_file_reader(f)
      defer zip.close_file_reader(f)

      fmt.print("File contents: ")
      for {
        n, err := io.read(r, buf[:])

        fmt.print(string(buf[:n]))
        if err != nil {
          break
        }
      }

      fmt.println()
      fmt.println("Last modified:", f.lastModifiedDateTime)
      fmt.println("----------------------------")
    }
  }

  fmt.println("Zip writing test:")
  {
    f, _ := os2.open("out.zip", {.Trunc, .Create, .Write})
    w := os2.to_writer(f)

    aw := zip.new_writer(w)
    defer zip.writer_close(aw)

    zip.set_comment(aw, "we can set the archive comment")

    for i in 0..<10 {
      filename := fmt.tprintf("test%d.txt", i)

      method := 0 // 0 means no compression
      if i%2 == 0 {
        method = 8 // Compress every even file
      }

      fw, _ := zip.create_file_extra(aw, zip.FileInfo{
        name = filename,
        method = method,
      })

      cont := fmt.tprintf("this is file #%d", i)

      fmt.println("Writing file", filename, "with contents -", cont)
      io.write_string(fw, cont)
    }

    fmt.println("Write done\n")
  }

  fmt.println("Reading out.zip:")
  {
    archive, err := zip.load_from_file("out.zip")
    defer zip.close_archive(&archive)
    if err != nil {
      fmt.println(err)
      return
    }

    buf := make([dynamic]byte, 64)
    delete(buf)

    for _, i in archive.files {
      f := &archive.files[i]

      r, _ := zip.open_file_reader(f)
      defer zip.close_file_reader(f)

      n, e := io.read(r, buf[:])
      fmt.println("Read file", f.name, "with contents -", string(buf[:n]))
    }
  }
}
