// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'video.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class VideoAdapter extends TypeAdapter<Video> {
  @override
  final int typeId = 1;

  @override
  Video read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Video(
      videoId: fields[0] as String,
      title: fields[1] as String,
      description: fields[2] as String?,
      thumbnailUrl: fields[3] as String,
      filePath: fields[4] as String?,
      downloadStatus: fields[5] as DownloadStatus,
      watched: fields[6] as bool,
      lastPositionSeconds: fields[7] as int,
      totalDurationSeconds: fields[8] as int,
      addedToPlaylistAt: fields[9] as DateTime,
      downloadedAt: fields[10] as DateTime?,
      downloadProgress: fields[11] as double,
      channelName: fields[12] as String,
      isDeleted: fields[13] as bool,
      deletedAt: fields[14] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, Video obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.videoId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.description)
      ..writeByte(3)
      ..write(obj.thumbnailUrl)
      ..writeByte(4)
      ..write(obj.filePath)
      ..writeByte(5)
      ..write(obj.downloadStatus)
      ..writeByte(6)
      ..write(obj.watched)
      ..writeByte(7)
      ..write(obj.lastPositionSeconds)
      ..writeByte(8)
      ..write(obj.totalDurationSeconds)
      ..writeByte(9)
      ..write(obj.addedToPlaylistAt)
      ..writeByte(10)
      ..write(obj.downloadedAt)
      ..writeByte(11)
      ..write(obj.downloadProgress)
      ..writeByte(12)
      ..write(obj.channelName)
      ..writeByte(13)
      ..write(obj.isDeleted)
      ..writeByte(14)
      ..write(obj.deletedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DownloadStatusAdapter extends TypeAdapter<DownloadStatus> {
  @override
  final int typeId = 0;

  @override
  DownloadStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return DownloadStatus.pending;
      case 1:
        return DownloadStatus.downloading;
      case 2:
        return DownloadStatus.completed;
      case 3:
        return DownloadStatus.failed;
      default:
        return DownloadStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, DownloadStatus obj) {
    switch (obj) {
      case DownloadStatus.pending:
        writer.writeByte(0);
        break;
      case DownloadStatus.downloading:
        writer.writeByte(1);
        break;
      case DownloadStatus.completed:
        writer.writeByte(2);
        break;
      case DownloadStatus.failed:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
