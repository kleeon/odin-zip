package zip

@(private="package")
LocalFileHeader :: struct #packed {
  signature: u32, // 0x04034b50
  versionNeeded: u16,
  flags: u16,
  compressionMethod: u16,
  lastModifiedTime: u16,
  lastModifiedDate: u16,
  crc32: u32,
  compressedSize: u32,
  uncompressedSize: u32,
  fileNameLength: u16,
  extraLength: u16,
}

@(private="package")
EOCD :: struct #packed {
  signature: u32, // 0x06054b50
  diskNum: u16,
  startDisk: u16,
  numberDirRecordsOnDisk: u16,
  numberDirRecords: u16,
  sizeOfCentralDirectory: u32,
  centralDirectoryOffset: u32,
  commentLength: u16,
}

@(private="package")
EOCD64 :: struct #packed {
  signature: u32, // 0x06064b50
  sizeOfEOCD: u64,
  versionMadeBy: u16,
  versionNeeded: u16,
  diskNum: u32,
  startDisk: u32,
  numberDirRecordsOnDisk: u64,
  numberDirRecords: u64,
  sizeOfCentralDirectory: u64,
  centralDirectoryStartOffset: u64,
}

@(private="package")
EOCD64Locator :: struct #packed {
  signature: u32, // 0x07064b50
  diskNumber: u32,
  eocd64Offset: u64,
  numberOfDisks: u32,
}

@(private="package")
CentralDirectoryFileHeader :: struct #packed {
  signature: u32, // 0x02014b50
  versionMadeBy : u16,
  versionNeeded : u16,
  flags: u16,
  compressionMethod: u16,
  lastModifiedTime: u16,
  lastModifiedDate: u16,
  crc32: u32,
  compressedSize: u32,
  uncompressedSize: u32,
  fileNameLength: u16,
  extraLength: u16,
  fileCommentLength: u16,
  diskNumberStart: u16,
  internFileAttrib: u16,
  externFileAttrib: u32,
  relOffsetOfLocalHeader: u32,
}

@(private="package")
ExtraFieldHeader :: struct #packed {
  header: u16,
  size: u16,
}

@(private="package")
CentralDirectoryFileHeader64 :: struct #packed {
  uncompressedSize: u64, // 0x06064b50
  compressedSize: u64,
  offsetOfLocalHeader: u64,
  diskNum: u32,
}

@(private="package")
DataDescriptor :: struct #packed {
  signature: u32, // 0x08074b50
  crc32: u32,
  compressedSize: u32,
  uncompressedSize: u32,
}

@(private="package")
DataDescriptor64 :: struct #packed {
  signature: u32, // 0x08074b50
  crc32: u32,
  compressedSize: u64,
  uncompressedSize: u64,
}
