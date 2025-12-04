// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playlist.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PlaylistAdapter extends TypeAdapter<Playlist> {
  @override
  final int typeId = 2;

  @override
  Playlist read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Playlist(
      playlistId: fields[0] as String,
      title: fields[1] as String,
      thumbnailUrl: fields[2] as String?,
      itemCount: fields[3] as int,
      lastSyncedAt: fields[4] as DateTime?,
      nextPageToken: fields[5] as String?,
      isOfflinePlaylist: fields[6] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, Playlist obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.playlistId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.thumbnailUrl)
      ..writeByte(3)
      ..write(obj.itemCount)
      ..writeByte(4)
      ..write(obj.lastSyncedAt)
      ..writeByte(5)
      ..write(obj.nextPageToken)
      ..writeByte(6)
      ..write(obj.isOfflinePlaylist);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
