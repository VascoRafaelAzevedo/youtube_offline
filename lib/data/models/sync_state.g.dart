// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_state.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SyncStateAdapter extends TypeAdapter<SyncState> {
  @override
  final int typeId = 3;

  @override
  SyncState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SyncState(
      lastFullSyncAt: fields[0] as DateTime?,
      isSyncing: fields[1] as bool,
      lastError: fields[2] as String?,
      totalVideosInPlaylist: fields[3] as int,
      downloadedVideosCount: fields[4] as int,
      watchedVideosCount: fields[5] as int,
      offlinePlaylistId: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, SyncState obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.lastFullSyncAt)
      ..writeByte(1)
      ..write(obj.isSyncing)
      ..writeByte(2)
      ..write(obj.lastError)
      ..writeByte(3)
      ..write(obj.totalVideosInPlaylist)
      ..writeByte(4)
      ..write(obj.downloadedVideosCount)
      ..writeByte(5)
      ..write(obj.watchedVideosCount)
      ..writeByte(6)
      ..write(obj.offlinePlaylistId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
