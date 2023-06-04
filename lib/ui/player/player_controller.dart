import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:harmonymusic/helper.dart';
import 'package:harmonymusic/models/media_Item_builder.dart';
import 'package:harmonymusic/ui/screens/playlistnalbum_screen_controller.dart';
import 'package:hive/hive.dart';
import 'package:audio_service/audio_service.dart';
import 'package:get/get.dart';

import '../../services/background_task.dart';
import '../widgets/sliding_up_panel.dart';
import '/models/durationstate.dart';
import '/services/music_service.dart';

class PlayerController extends GetxController {
  final _audioHandler = Get.find<AudioHandler>();
  final _musicServices = Get.find<MusicServices>();
  final currentQueue = <MediaItem>[].obs;

  final playerPaneOpacity = (1.0).obs;
  final isPlayerpanelTopVisible = true.obs;
  final isPlayerPaneDraggable = true.obs;
  final playerPanelMinHeight = 0.0.obs;
  bool _initFlagForPlayer = true;
  final isQueueReorderingInProcess = false.obs;
  PanelController playerPanelController = PanelController();

  final progressBarStatus = ProgressBarState(
          buffered: Duration.zero, current: Duration.zero, total: Duration.zero)
      .obs;

  final currentSongIndex = (0).obs;
  final isFirstSong = true;
  final isLastSong = true;
  final isLoopModeEnabled = false.obs;
  final currentSong = Rxn<MediaItem>();
  final isCurrentSongFav = false.obs;
  ScrollController scrollController = ScrollController();
  final GlobalKey<ScaffoldState> homeScaffoldkey = GlobalKey<ScaffoldState>();

  final buttonState = PlayButtonState.paused.obs;

  var _newSongFlag = true;
  final isCurrentSongBuffered = false.obs;

  late StreamSubscription<bool> keyboardSubscription;

  PlayerController() {
    _init();
  }

  void _init() async {
    //_createAppDocDir();
    _listenForChangesInPlayerState();
    _listenForChangesInPosition();
    _listenForChangesInBufferedPosition();
    _listenForChangesInDuration();
    _listenForPlaylistChange();
    _listenForKeyboardActivity();
  }

  void panellistener(double x) {
    if (x >= 0 && x <= 0.2) {
      playerPaneOpacity.value = 1 - (x * 5);
      isPlayerpanelTopVisible.value = true;
    }
    if (x > 0.2) {
      isPlayerpanelTopVisible.value = false;
    }
    if (x > 0) {
      isPlayerPaneDraggable.value = false;
    } else {
      isPlayerPaneDraggable.value = true;
    }
  }

  void _listenForKeyboardActivity() {
    var keyboardVisibilityController = KeyboardVisibilityController();
    keyboardSubscription =
        keyboardVisibilityController.onChange.listen((bool visible) {
      visible?playerPanelController.hide():playerPanelController.show();
    });
  }

  void _listenForChangesInPlayerState() {
    _audioHandler.playbackState.listen((playerState) {
      final isPlaying = playerState.playing;
      final processingState = playerState.processingState;
      if (processingState == AudioProcessingState.loading ||
          processingState == AudioProcessingState.buffering) {
        buttonState.value = PlayButtonState.loading;
      } else if (!isPlaying) {
        buttonState.value = PlayButtonState.paused;
      } else if (processingState != AudioProcessingState.completed) {
        buttonState.value = PlayButtonState.playing;
      } else {
        _audioHandler.seek(Duration.zero);
        _audioHandler.pause();
      }
    });
  }

  void _listenForChangesInPosition() {
    AudioService.position.listen((position) {
      final oldState = progressBarStatus.value;
      progressBarStatus.update((val) {
        val!.current = position;
        val.buffered = oldState.buffered;
        val.total = oldState.total;
      });
    });
  }

  void _listenForChangesInBufferedPosition() {
    _audioHandler.playbackState.listen((playbackState) {
      final oldState = progressBarStatus.value;
      if (playbackState.bufferedPosition.inSeconds /
              progressBarStatus.value.total.inSeconds ==
          1) {
        if (_newSongFlag) {
          _audioHandler.customAction(
              "checkWithCacheDb", {'mediaItem': currentSong.value!});
          _newSongFlag = false;
        }
      }
      progressBarStatus.update((val) {
        val!.buffered = playbackState.bufferedPosition;
        val.current = oldState.current;
        val.total = oldState.total;
      });
    });
  }

  void _listenForChangesInDuration() {
    _audioHandler.mediaItem.listen((mediaItem) async {
      final oldState = progressBarStatus.value;
      progressBarStatus.update((val) {
        val!.total = mediaItem?.duration ?? Duration.zero;
        val.current = oldState.current;
        val.buffered = oldState.buffered;
      });
      if (mediaItem != null) {
        printINFO(mediaItem.title);
        _newSongFlag = true;
        isCurrentSongBuffered.value = false;
        currentSong.value = mediaItem;
        currentSongIndex.value = currentQueue
            .indexWhere((element) => element.id == currentSong.value!.id);
        await _checkFav();
        await _addToRP(currentSong.value!);
      }
    });
  }

  void _listenForPlaylistChange() {
    _audioHandler.queue.listen((queue) {
      currentQueue.value = queue;
      currentQueue.refresh();
    });
  }

  ///pushSongToPlaylist method clear previous song queue, plays the tapped song and push related
  ///songs into Queue
  Future<void> pushSongToQueue(MediaItem mediaItem) async {
    ReceivePort receivePort = ReceivePort();
    Isolate.spawn(
        getUpNextSong, [receivePort.sendPort, _musicServices, mediaItem.id]);
    receivePort.first.then((value) async {
      final upNextSongList = value;
      await _audioHandler.updateQueue(upNextSongList);
    });

    //open player panel,set current song and push first song into playing list,
    currentSong.value = mediaItem;
    _playerPanelCheck();
    await _audioHandler.customAction(
        "setSourceNPlay", {'mediaItem': mediaItem});
  }

  ///enqueueSong   append a song to current queue
  ///if current queue is empty, push the song into Queue and play that song
  Future<void> enqueueSong(MediaItem mediaItem) async {
    //check if song is available in cache and allocate
    await enqueueSongList([mediaItem]);
  }

  ///enqueueSongList method add song List to current queue
  Future<void> enqueueSongList(List<MediaItem> mediaItems) async {
    if(currentQueue.isEmpty){
     await playPlayListSong(mediaItems, 0);
      return;
    }
    for(MediaItem item in mediaItems){
      if(!currentQueue.contains(item)){
        _audioHandler.addQueueItem(item);
      }
    }
  }

  Future<void> playASong(MediaItem mediaItem) async {
    currentSong.value = mediaItem;
    _playerPanelCheck();
    await _audioHandler.customAction(
        "setSourceNPlay", {'mediaItem': mediaItem});
  }

  Future<void> playPlayListSong(List<MediaItem> mediaItems, int index) async {
    //open player pane,set current song and push first song into playing list,
    final init = _initFlagForPlayer;
    currentSong.value = mediaItems[index];
    _playerPanelCheck();
    !init
        ? await _audioHandler.updateQueue(mediaItems)
        : _audioHandler.addQueueItems(mediaItems);
    await _audioHandler.customAction("playByIndex", {"index": index});
  }

  void _playerPanelCheck() {
    if (playerPanelController.isAttached) {
      playerPanelController.open();
    }

    if (_initFlagForPlayer) {
      playerPanelMinHeight.value = 75.0 + Get.mediaQuery.viewPadding.bottom;
      _initFlagForPlayer = false;
    }
  }

  void removeFromQueue(MediaItem song){
    _audioHandler.removeQueueItem(song);
  }

  void shuffleQueue(){
    _audioHandler.customAction("shuffleQueue");
  }

  void onReorder(int oldIndex,int newIndex){
    printINFO("Reorder");
    _audioHandler.customAction("reorderQueue",{"oldIndex":oldIndex,"newIndex":newIndex});
  }

  void onReorderStart(int index){
    printINFO("Reordering started");
    isQueueReorderingInProcess.value = true;
  }

  void onReorderEnd(int index){
     printINFO("Reordering ended");
    isQueueReorderingInProcess.value = false;
  }

  void play() {
    _audioHandler.play();
  }

  void pause() {
    _audioHandler.pause();
  }

  void prev() {
    _audioHandler.skipToPrevious();
  }

  Future<void> next() async {
    await _audioHandler.skipToNext();
  }

  void seek(Duration position) {
    _audioHandler.seek(position);
  }

  void seekByIndex(int index) {
    _audioHandler.customAction("playByIndex", {"index": index});
  }

  void toggleSkipSilence(bool enable) {
    _audioHandler.customAction("toggleSkipSilence", {"enable": enable});
  }

  void toggleLoopMode() {
    isLoopModeEnabled.isFalse
        ? _audioHandler.setRepeatMode(AudioServiceRepeatMode.one)
        : _audioHandler.setRepeatMode(AudioServiceRepeatMode.none);
    isLoopModeEnabled.value = !isLoopModeEnabled.value;
  }

  Future<void> _checkFav() async {
    isCurrentSongFav.value =
        (await Hive.openBox("LIBFAV")).containsKey(currentSong.value!.id);
  }

  Future<void> toggleFavourite() async {
    final currMediaItem = currentSong.value!;
    final box = await Hive.openBox("LIBFAV");
    isCurrentSongFav.isFalse
        ? box.put(currMediaItem.id, MediaItemBuilder.toJson(currMediaItem))
        : box.delete(currMediaItem.id);
    try {
      final playlistController = Get.find<PlayListNAlbumScreenController>();
      if (playlistController.isAlbum.isFalse &&
          playlistController.id == "LIBFAV") {
        isCurrentSongFav.isFalse
            ? playlistController.addNRemoveItemsinList(currMediaItem,
                action: 'add', index: 0)
            : playlistController.addNRemoveItemsinList(currMediaItem,
                action: 'remove');
      }
    // ignore: empty_catches
    } catch (e) {}
    isCurrentSongFav.value = !isCurrentSongFav.value;
  }

  // ignore: prefer_typing_uninitialized_variables
  var recentItem;

  /// This function is used to add a mediaItem/Song to Recently played playlist
  Future<void> _addToRP(MediaItem mediaItem) async {
    final box = await Hive.openBox("LIBRP");
    if (box.keys.length > 20) box.deleteAt(0);
    if (recentItem != mediaItem) {
      box.add(MediaItemBuilder.toJson(mediaItem));
      try {
        final playlistController = Get.find<PlayListNAlbumScreenController>();
        if (playlistController.isAlbum.isFalse &&
            playlistController.id == "LIBRP") {
          if (playlistController.songList.length > 20) {
            playlistController.addNRemoveItemsinList(null,
                action: 'remove',
                index: playlistController.songList.length - 1);
          }
          playlistController.addNRemoveItemsinList(mediaItem,
              action: 'add', index: 0);
        }
      // ignore: empty_catches
      } catch (e) {}
    }
    recentItem = mediaItem;
  }


  @override
  void dispose() {
    _audioHandler.customAction('dispose');
    keyboardSubscription.cancel();
    scrollController.dispose();
    super.dispose();
  }
}

enum PlayButtonState { paused, playing, loading }
