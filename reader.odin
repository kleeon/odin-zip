package zip

import "core:os"
import "vendor:zlib"
import "core:bufio"
import "core:io"
import "core:strings"
import "core:math"
import "core:time"
import "core:bytes"

File :: struct {
  name: string,
  comment: string,
  compressedSize: u64,
  uncompressedSize: u64,
  compressionMethod: u32,
  lastModifiedDateTime: time.Time,
  crc32: u32,

  _dataOffset: u64,
  _rd: io.Reader_At,
  _state: rawptr,
  _destroy: proc(rawptr),
}

Reader :: struct {
  files: [dynamic]File,
  comment: string,

  f: os.Handle,
  r: io.Reader_At,
  size: i64,
}

Error :: enum {
  None = 0,
  Read_Error,
  Read_Seek_Not_Implemented,
  Invalid_Zip_File,
  Memory_Allocation_Error,
  Unexpected_EOF,
  Unsupported_Compression_Method,
  Name_Too_Long,
  Comment_Too_Long,
  Write_Error,
  Flush_Error,
}

load_from_slice :: proc(s: []byte) -> (arch: Reader, err: Error) {
  r: bytes.Reader
  bytes.reader_init(&r, s)
  ra := io.to_reader_at(bytes.reader_to_stream(&r))

  arch, err = load_from_reader_at(ra, i64(len(s)))

  return
}

load_from_file :: proc(filename: string) -> (arch: Reader, err: Error) {
  fh, e := os.open(filename, os.O_RDONLY)
  if e != 0 {
    err = .Read_Error
    return
  }

  fileSize: i64 = ---
  fileSize, e = os.file_size(fh)
  if e != 0 {
    err = .Read_Error
    return
  }

  s := os.stream_from_handle(fh)

  arch, err = load_from_reader_at(io.to_reader_at(s), fileSize)
  arch.f = fh

  return
}

load_from_reader_at :: proc(rd: io.Reader_At, size: i64) -> (Reader, Error) {
  // rd should technically be Read_Seeker, but there is no such type in the core library.
  if rd.stream.impl_read == nil || rd.stream.impl_seek == nil {
    return {}, .Read_Seek_Not_Implemented
  }

  sig: [2]byte
  n, e := io.read(io.to_reader(rd.stream), sig[:])
  if e != nil {
    return {}, .Read_Error
  }

  if size < size_of(EOCD) || sig[0] != '\x50' || sig[1] != '\x4B' {
    return {}, .Invalid_Zip_File
  }

  eocd: ^EOCD

  MAX_EOCD_SIZE :: 64 * 1024 + size_of(EOCD)
  buf := make([dynamic]byte, min(MAX_EOCD_SIZE, size))
  defer delete(buf)

  n, e = io.read_at(rd, buf[:], max(size - MAX_EOCD_SIZE, 0))
  if e != nil {
    return {}, .Read_Error
  }

  offs := size_of(EOCD)
  idx := i64(len(buf) - offs)

  for offs < MAX_EOCD_SIZE && idx >= 0 {
    if buf[idx] == '\x50' && buf[idx+1] == '\x4B' {
      eocd = transmute(^EOCD)&(buf[idx])
      break
    }

    offs += 1
    idx = i64(len(buf) - offs)
  }

  if eocd == nil {
    return {}, .Invalid_Zip_File
  }

  EOCDIdx := size - i64(offs)

  archive: Reader
  archive.r = rd

  br: bufio.Reader
  buffered_reader_at(&br, rd, u64(EOCDIdx + size_of(EOCD)))
  defer bufio.reader_destroy(&br)

  archCommentLen := int(eocd.commentLength)
  archive.comment = read_string(&br, archCommentLen)
  if len(archive.comment) != archCommentLen {
    return archive, .Unexpected_EOF
  }

  numberDirRecords := u64(eocd.numberDirRecords)
  centralDirectoryOffset := u64(eocd.centralDirectoryOffset)
  sizeOfCentralDirectory := u64(eocd.sizeOfCentralDirectory)

  // Handle ZIP64
  if eocd.numberDirRecords == 0xffff || eocd.sizeOfCentralDirectory == 0xffffffff || eocd.centralDirectoryOffset == 0xffffffff {
    idx = EOCDIdx - size_of(EOCD64Locator)
    if idx < size_of(EOCD64) {
      return {}, .Unexpected_EOF
    }

    buffered_reader_at(&br, rd, u64(idx))
    n := read_all(&br, get_slice(&buf, int(size_of(EOCD64Locator))))
    if n < size_of(EOCD64Locator) {
      return {}, .Unexpected_EOF
    }

    loc := transmute(^EOCD64Locator)&(buf[0])
    if loc.signature == 0x07064b50 {
      idx = i64(loc.eocd64Offset)

      buffered_reader_at(&br, rd, u64(idx))
      n := read_all(&br, get_slice(&buf, int(size_of(EOCD64))))
      if n < size_of(EOCD64) {
        return {}, .Unexpected_EOF
      }

      eocd64 := transmute(^EOCD64)&(buf[0])
      if eocd64.signature != 0x06064b50 {
        return {}, .Invalid_Zip_File
      }

      numberDirRecords = eocd64.numberDirRecords
      centralDirectoryOffset = eocd64.centralDirectoryStartOffset
      sizeOfCentralDirectory = eocd64.sizeOfCentralDirectory
    }
  }

  // Number of files is stored in the EOCD record.
  // Before pre-allocating space for files we should check if the size is reasonable.
  if (u64(size) - sizeOfCentralDirectory) / 30 >= numberDirRecords && numberDirRecords > 0 {
    archive.files = make([dynamic]File, 0, numberDirRecords)

    if archive.files == nil {
      return {}, .Memory_Allocation_Error
    }
  }

  base := centralDirectoryOffset
  buffered_reader_at(&br, rd, base)

  // Read file info from central directory
  for {
    n = read_all(&br, get_slice(&buf, size_of(CentralDirectoryFileHeader)))
    if n != size_of(CentralDirectoryFileHeader) {
      break
    }

    cdfh := transmute(^CentralDirectoryFileHeader)&(buf[0])
    if cdfh.signature != 0x02014b50 {
      break
    }

    f: File = ---
    f.compressedSize       = u64(cdfh.compressedSize)
    f.uncompressedSize     = u64(cdfh.uncompressedSize)
    f.compressionMethod    = u32(cdfh.compressionMethod)
    f.lastModifiedDateTime = time_from_dos_time_and_date(cdfh.lastModifiedTime, cdfh.lastModifiedDate)
    f.crc32                = cdfh.crc32
    f._dataOffset          = u64(cdfh.relOffsetOfLocalHeader)
    f._rd                  = rd
    f._state               = nil
    f._destroy             = nil

    fileNameLen := int(cdfh.fileNameLength)
    commentLen  := int(cdfh.fileCommentLength)
    extraLen    := int(cdfh.extraLength)

    f.name = read_string(&br, fileNameLen)
    if len(f.name) != fileNameLen {
      return archive, .Unexpected_EOF
    }

    n = read_all(&br, get_slice(&buf, extraLen))
    if n != extraLen {
      return archive, .Unexpected_EOF
    }

    // Read extra field
    for idx = 0; n >= 4 && idx <= i64(n - 4); {
      head := transmute(^ExtraFieldHeader)&buf[idx]
      idx += 4
      bodySize := min(i64(extraLen) - idx, i64(head.size))
      defer idx += bodySize

      switch head.header {
        case 0x0001: { // ZIP64
          cdfh64 := transmute(^CentralDirectoryFileHeader64)&buf[idx]

          if bodySize < 8 {
            continue
          }
          if f.compressedSize == 0xffffffff {
            f.compressedSize = cdfh64.compressedSize
          }

          if bodySize < 16 {
            continue
          }
          if f.uncompressedSize == 0xffffffff {
            f.uncompressedSize = cdfh64.uncompressedSize
          }

          if bodySize < 24 {
            continue
          }
          if f._dataOffset == 0xffffffff {
            f._dataOffset = cdfh64.offsetOfLocalHeader
          }
        }
      }
    }

    f.comment = read_string(&br, commentLen)
    if len(f.comment) != commentLen {
      return archive, .Unexpected_EOF
    }

    append(&archive.files, f)
  }

  return archive, .None
}

close_archive :: proc(arch: ^Reader) {
  if arch.f != 0 {
    os.close(arch.f)
    arch.f = 0
  }

  delete(arch.comment)

  for f, i in arch.files {
    delete(f.name)
    delete(f.comment)
    close_file_reader(&arch.files[i])
  }

  delete(arch.files)
}

@(private)
read_all :: proc(r: ^bufio.Reader, b: []byte) -> int {
  if len(b) == 0 {
    return 0
  }

  offs := 0
  for {
    n, _ := bufio.reader_read(r, b[offs:])
    offs += n
    if offs == len(b) || n == 0 {
      break
    }
  }

  return offs
}

@(private)
buffered_reader_at :: proc(br: ^bufio.Reader, r: io.Reader_At, offset: u64) {
  io.seek(io.to_seeker(r.stream), i64(offset), .Start)

  if len(br.buf) == 0 {
    bufio.reader_init(br, io.to_reader(r.stream), 64 * 1024)
  }
  else {
    bufio.reader_reset(br, io.to_reader(r.stream))
  }
}

@(private)
read_string :: proc(br: ^bufio.Reader, len: int) -> string {
  if len <= 0 {
    return ""
  }

  b := make([]byte, len) // This is not great. Should probably be replaced with block allocator
  n := read_all(br, b)

  return string(b[:n])
}

@(private)
get_slice :: proc(buf: ^[dynamic]byte, n: int) -> []byte {
  if cap(buf) <= n {
    newSize := 1 << uint(math.ceil(math.log2(f64(n))))
    resize(buf, newSize)
  }

  return buf[:n]
}

@(private)
time_from_dos_time_and_date :: proc(t: u16, d: u16) -> (res: time.Time) {
  // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-filetimetodosdatetime
  s := int(t & 0b11111)*2
  m := int((t >> 5) & 0b111111)
  h := int(t >> 11)

  da := int(d & 0b11111)
  mn := int((d >> 5) & 0b1111)
  y  := int(d >> 9) + 1980

  res, _ = time.datetime_to_time(y, mn, da, h, m, s)
  return
}

@(private)
InflateContext :: struct {
  zStream: zlib.z_stream,
  r: ^io.Reader_At,
  buf: []byte,
  avail: u64,
}

@(private)
inflate_read :: proc(ctx: ^InflateContext, p: []byte) -> (n: int, err: io.Error) {
  zs := &ctx.zStream

  if ctx.avail == 0 {
    err = .EOF
    return
  }

  outOffs: u64
  prevAvailIn: u32

  for {
    zs.total_out = 0

    zs.next_out  = &p[outOffs]
    // Make sure not to overflow when compressing more than 4 gigs of data
    zs.avail_out = u32(min(u64(len(p)) - outOffs, u64(0xffffffff)))

    nr := int(zs.avail_in)
    if zs.avail_in == 0 {
      nr, err = io.read(io.to_reader(ctx.r.stream), ctx.buf[:min(ctx.avail, u64(len(ctx.buf)))])
      if err != nil {
        break
      }
      zs.total_in = 0
    }

    zs.next_in  = &ctx.buf[zs.total_in]
    zs.avail_in = u32(nr)
    prevAvailIn = zs.avail_in

    e := zlib.inflate(&ctx.zStream, zlib.BLOCK)
    ctx.avail -= u64(prevAvailIn-zs.avail_in)

    if e == zlib.STREAM_END {
      break
    }

    outOffs += u64(zs.total_out)
    if outOffs >= u64(len(p)) {
      break
    }
  }

  n = int(outOffs)

  return
}

@(private)
make_inflate_reader :: proc(f: ^File) -> (r: io.Reader) {
  ctx := new(InflateContext)
  ctx.r     = &f._rd
  ctx.buf   = make([]byte, 4096)
  ctx.avail = f.compressedSize
  zlib.inflateInit2(&ctx.zStream, -15)

  f._state = ctx
  f._destroy = proc(state: rawptr) {
    ctx := (^InflateContext)(state)
    zlib.inflateEnd(&ctx.zStream)
    delete(ctx.buf)
  }

  r.stream_data = ctx
  r.stream_vtable = &_inflate_stream_vtable
  return
}

@(private)
_inflate_stream_vtable := io.Stream_VTable{
  impl_read = proc(s: io.Stream, p: []byte) -> (n: int, err: io.Error) {
    return inflate_read((^InflateContext)(s.stream_data), p)
  },
}

open_file_reader :: proc(f: ^File) -> (io.Reader, Error) {
  io.seek(io.to_seeker(f._rd.stream), i64(f._dataOffset), .Start)
  head: [size_of(LocalFileHeader)]byte

  r := io.to_reader(f._rd.stream)
  io.read(r, head[:])
  h := transmute(^LocalFileHeader)&head[0]

  extraLength      := i64(h.extraLength)
  nameLength       := i64(h.fileNameLength)
  uncompressedSize := i64(f.uncompressedSize)
  io.seek(io.to_seeker(f._rd.stream), extraLength + nameLength, .Current)

  switch f.compressionMethod {
    case 0: // STORE
      l := new(io.Limited_Reader)
      f._state = l
      return io.limited_reader_init(l, r, uncompressedSize), nil
    case 8: // DEFLATE
      return make_inflate_reader(f), nil
    case:
      return {}, .Unsupported_Compression_Method
  }
}

close_file_reader :: proc(f: ^File) {
  if f._destroy != nil {
    f._destroy(f._state)
    f._destroy = nil
  }
  if f._state != nil {
    free(f._state)
    f._state = nil
  }
}
