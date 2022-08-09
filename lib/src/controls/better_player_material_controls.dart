import 'dart:async';
import 'dart:ui';

import 'package:better_player/src/configuration/better_player_controls_configuration.dart';
import 'package:better_player/src/controls/better_player_clickable_widget.dart';
import 'package:better_player/src/controls/better_player_controls_state.dart';
import 'package:better_player/src/controls/better_player_material_progress_bar.dart';
import 'package:better_player/src/controls/better_player_multiple_gesture_detector.dart';
import 'package:better_player/src/controls/better_player_progress_colors.dart';
import 'package:better_player/src/core/better_player_controller.dart';
import 'package:better_player/src/core/better_player_utils.dart';
import 'package:better_player/src/video_player/video_player.dart';
// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quds_popup_menu/quds_popup_menu.dart';

import '../core/better_player_on_tap_effect.dart';

class BetterPlayerMaterialControls extends StatefulWidget {
  ///Callback used to send information if player bar is hidden or not
  final Function(bool visbility) onControlsVisibilityChanged;

  ///Controls config
  final BetterPlayerControlsConfiguration controlsConfiguration;

  const BetterPlayerMaterialControls({
    Key? key,
    required this.onControlsVisibilityChanged,
    required this.controlsConfiguration,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _BetterPlayerMaterialControlsState();
  }
}

class _BetterPlayerMaterialControlsState
    extends BetterPlayerControlsState<BetterPlayerMaterialControls> {
  VideoPlayerValue? _latestValue;
  double? _latestVolume;
  Timer? _hideTimer;
  Timer? _initTimer;
  Timer? _showAfterExpandCollapseTimer;
  bool _displayTapped = false;
  bool _wasLoading = false;
  VideoPlayerController? _controller;
  BetterPlayerController? _betterPlayerController;
  StreamSubscription? _controlsVisibilityStreamSubscription;

  BetterPlayerControlsConfiguration get _controlsConfiguration =>
      widget.controlsConfiguration;

  @override
  VideoPlayerValue? get latestValue => _latestValue;

  @override
  BetterPlayerController? get betterPlayerController => _betterPlayerController;

  @override
  BetterPlayerControlsConfiguration get betterPlayerControlsConfiguration =>
      _controlsConfiguration;

  @override
  Widget build(BuildContext context) {
    return buildLTRDirectionality(_buildMainWidget());
  }

  ///Builds main widget of the controls.
  Widget _buildMainWidget() {
    _wasLoading = isLoading(_latestValue);
    if (_latestValue?.hasError == true) {
      return Container(
        color: Colors.black,
        child: _buildErrorWidget(),
      );
    }
    return GestureDetector(
      onTap: () {
        if (BetterPlayerMultipleGestureDetector.of(context) != null) {
          BetterPlayerMultipleGestureDetector.of(context)!.onTap?.call();
        }
        controlsNotVisible
            ? cancelAndRestartTimer()
            : changePlayerControlsNotVisible(true);
      },
      onDoubleTap: () {
        if (BetterPlayerMultipleGestureDetector.of(context) != null) {
          BetterPlayerMultipleGestureDetector.of(context)!.onDoubleTap?.call();
        }
        cancelAndRestartTimer();
      },
      onLongPress: () {
        if (BetterPlayerMultipleGestureDetector.of(context) != null) {
          BetterPlayerMultipleGestureDetector.of(context)!.onLongPress?.call();
        }
      },
      child: AbsorbPointer(
        absorbing: controlsNotVisible,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_wasLoading)
              Center(child: _buildLoadingWidget())
            else
              _buildHitArea(),
            _betterPlayerController!.isFullScreen ||
                    _controlsConfiguration.enableBackButton
                ? Positioned(
                    top: 16,
                    left: 16,
                    child: _buildBackDetails(),
                  )
                : SizedBox.shrink(),
            Positioned(
              top: 16,
              right: 16,
              child: _buildMuteButton(_controller),
            ),
            Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),
            _buildNextVideoWidget(),
          ],
        ),
      ),
    );
  }

  List<QudsPopupMenuBase> getMenuItems() {
    String quality =
        betterPlayerController!.betterPlayerDataSource!.resolutions!.entries
            .firstWhere(
              (element) =>
                  element.value ==
                  betterPlayerController!.betterPlayerDataSource!.url,
            )
            .key;

    return [
      QudsPopupMenuSection(
        backgroundColor: Colors.transparent,
        titleText: 'Playback speed',
        leading: Icon(
          _controlsConfiguration.playbackSpeedIcon,
          color: Colors.white,
        ),
        selectedValue: Text(
          "${betterPlayerController!.videoPlayerController!.value.speed}x",
          style: TextStyle(color: Colors.white),
        ),
        subItems: [
          _buildPlaybackSpeedPopup(0.25),
          _buildPlaybackSpeedPopup(0.5),
          _buildPlaybackSpeedPopup(0.75),
          _buildPlaybackSpeedPopup(1.0, name: "Normal"),
          _buildPlaybackSpeedPopup(1.25),
          _buildPlaybackSpeedPopup(1.5),
          _buildPlaybackSpeedPopup(1.75),
          _buildPlaybackSpeedPopup(2.0),
        ],
      ),
      QudsPopupMenuDivider(),
      QudsPopupMenuSection(
        leading: Icon(
          _controlsConfiguration.qualitiesIcon,
          color: Colors.white,
        ),
        selectedValue: Text("$quality", style: TextStyle(color: Colors.white)),
        titleText: 'Quality',
        subItems: showQualities(),
      ),
    ];
  }

  List<QudsPopupMenuBase> showQualities() {
    List<QudsPopupMenuBase> children = [];
    // normal videos
    final resolutions =
        betterPlayerController!.betterPlayerDataSource!.resolutions;
    resolutions?.forEach((key, value) {
      children.add(_buildResolutionSelectionRow(key, value));
    });

    return children;
  }

  QudsPopupMenuBase _buildResolutionSelectionRow(String name, String url) {
    final bool isSelected =
        url == betterPlayerController!.betterPlayerDataSource!.url;
    bool isHD = name == "1080p" || name == "720p";
    return QudsPopupMenuItem(
      leading: Visibility(
        visible: isSelected,
        child: Icon(
          Icons.check_outlined,
          color: Colors.white,
        ),
      ),
      title: Row(
        children: [
          Text(
            '$name ',
            style: TextStyle(color: Colors.white),
          ),
          if (isHD)
            Text(
              "HD",
              style: TextStyle(color: Colors.red),
            )
        ],
      ),
      onPressed: () {
        betterPlayerController!.setResolution(url);
      },
    );
  }

  QudsPopupMenuItem _buildPlaybackSpeedPopup(double value, {String? name}) {
    final bool isSelected =
        betterPlayerController!.videoPlayerController!.value.speed == value;
    return QudsPopupMenuItem(
      leading: Visibility(
        visible: isSelected,
        child: Icon(
          Icons.check_outlined,
          color: Colors.white,
        ),
      ),
      title: Text(
        '${name ?? '${value}x'}',
        style: TextStyle(color: Colors.white),
      ),
      onPressed: () {
        betterPlayerController!.setSpeed(value);
      },
    );
  }

  Widget _buildBackDetails() {
    if (!betterPlayerController!.controlsEnabled) {
      return const SizedBox();
    }
    return AnimatedOpacity(
      opacity: controlsNotVisible ? 0.0 : 1.0,
      duration: _controlsConfiguration.controlsHideTime,
      onEnd: _onPlayerHide,
      child: Row(
        children: [
          OnTapClick(
            onTap: () {
              Navigator.pop(context);
              SystemChrome.setPreferredOrientations([
                DeviceOrientation.portraitDown,
                DeviceOrientation.portraitUp,
              ]);
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(50),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.4),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 20,
                        color: Colors.grey.withOpacity(0.75),
                      )
                    ],
                  ),
                  child: Icon(
                    _controlsConfiguration.backIcon,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: 16.0),
          Visibility(
            visible: !_controlsConfiguration.enableBackButton,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  VerticalDivider(
                    width: 4,
                    thickness: 4,
                    color: Color(0xFFFFC947),
                  ),
                  SizedBox(width: 16.0),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          _controlsConfiguration.title ?? "",
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            shadows: [
                              Shadow(
                                color: Colors.black.withOpacity(0.5),
                                blurRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          _controlsConfiguration.subtitle ?? "",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(
                                color: Colors.black.withOpacity(0.5),
                                blurRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  void _dispose() {
    _controller?.removeListener(_updateState);
    _hideTimer?.cancel();
    _initTimer?.cancel();
    _showAfterExpandCollapseTimer?.cancel();
    _controlsVisibilityStreamSubscription?.cancel();
  }

  @override
  void didChangeDependencies() {
    final _oldController = _betterPlayerController;
    _betterPlayerController = BetterPlayerController.of(context);
    _controller = _betterPlayerController!.videoPlayerController;
    _latestValue = _controller!.value;

    if (_oldController != _betterPlayerController) {
      _dispose();
      _initialize();
    }

    super.didChangeDependencies();
  }

  Widget _buildErrorWidget() {
    final errorBuilder =
        _betterPlayerController!.betterPlayerConfiguration.errorBuilder;
    if (errorBuilder != null) {
      return errorBuilder(
          context,
          _betterPlayerController!
              .videoPlayerController!.value.errorDescription);
    } else {
      final textStyle = TextStyle(color: _controlsConfiguration.textColor);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.warning,
              color: _controlsConfiguration.iconsColor,
              size: 42,
            ),
            Text(
              _betterPlayerController!.translations.generalDefaultError,
              style: textStyle,
            ),
            if (_controlsConfiguration.enableRetry)
              TextButton(
                onPressed: () {
                  _betterPlayerController!.retryDataSource();
                },
                child: Text(
                  _betterPlayerController!.translations.generalRetry,
                  style: textStyle.copyWith(fontWeight: FontWeight.bold),
                ),
              )
          ],
        ),
      );
    }
  }

  Widget _buildTopBar() {
    if (!betterPlayerController!.controlsEnabled) {
      return const SizedBox();
    }

    return Container(
      child: (_controlsConfiguration.enableOverflowMenu)
          ? AnimatedOpacity(
              opacity: controlsNotVisible ? 0.0 : 1.0,
              duration: _controlsConfiguration.controlsHideTime,
              onEnd: _onPlayerHide,
              child: Container(
                height: _controlsConfiguration.controlBarHeight,
                width: double.infinity,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_controlsConfiguration.enablePip)
                      _buildPipButtonWrapperWidget(
                          controlsNotVisible, _onPlayerHide)
                    else
                      const SizedBox(),
                    _buildMoreButton(),
                  ],
                ),
              ),
            )
          : const SizedBox(),
    );
  }

  Widget _buildPipButton() {
    return BetterPlayerMaterialClickableWidget(
      onTap: () {
        betterPlayerController!.enablePictureInPicture(
            betterPlayerController!.betterPlayerGlobalKey!);
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          betterPlayerControlsConfiguration.pipMenuIcon,
          color: betterPlayerControlsConfiguration.iconsColor,
        ),
      ),
    );
  }

  Widget _buildPipButtonWrapperWidget(
      bool hideStuff, void Function() onPlayerHide) {
    return FutureBuilder<bool>(
      future: betterPlayerController!.isPictureInPictureSupported(),
      builder: (context, snapshot) {
        final bool isPipSupported = snapshot.data ?? false;
        if (isPipSupported &&
            _betterPlayerController!.betterPlayerGlobalKey != null) {
          return AnimatedOpacity(
            opacity: hideStuff ? 0.0 : 1.0,
            duration: betterPlayerControlsConfiguration.controlsHideTime,
            onEnd: onPlayerHide,
            child: Container(
              height: betterPlayerControlsConfiguration.controlBarHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _buildPipButton(),
                ],
              ),
            ),
          );
        } else {
          return const SizedBox();
        }
      },
    );
  }

  Widget _buildMoreButton() {
    if (_betterPlayerController!.isFullScreen)
      return QudsPopupButton(
        backgroundColor: Colors.transparent,
        tooltip: 'Settings',
        items: getMenuItems(),
        offset: Offset(0, -10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            _controlsConfiguration.overflowMenuIcon,
            size: 16,
            color: _betterPlayerController!.isFullScreen
                ? _controlsConfiguration.iconsColor
                : Colors.black87,
            shadows: [
              Shadow(
                blurRadius: 20,
                color: Colors.grey.withOpacity(0.75),
              )
            ],
          ),
        ),
      );

    return GestureDetector(
      onTap: () {
        onShowMoreClicked();
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          _controlsConfiguration.overflowMenuIcon,
          size: 16,
          color: _betterPlayerController!.isFullScreen
              ? _controlsConfiguration.iconsColor
              : Colors.black87,
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    if (!betterPlayerController!.controlsEnabled) {
      return const SizedBox();
    }
    return AnimatedOpacity(
      opacity: controlsNotVisible ? 0.0 : 1.0,
      duration: _controlsConfiguration.controlsHideTime,
      onEnd: _onPlayerHide,
      child: ClipRect(
        child: BackdropFilter(
          filter: new ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  Colors.white.withOpacity(0.4),
                  Colors.white.withOpacity(0.6),
                ],
              ),
            ),
            height: _controlsConfiguration.controlBarHeight,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: [
                      // if (_controlsConfiguration.enablePlayPause)
                      //   _buildPlayPause(_controller!)
                      // else
                      //   const SizedBox(),
                      if (_betterPlayerController!.isLiveStream())
                        _buildLiveWidget()
                      else
                        _controlsConfiguration.enableProgressText
                            ? _buildPosition()
                            : const SizedBox(),
                      if (_betterPlayerController!.isLiveStream())
                        const SizedBox()
                      else
                        _controlsConfiguration.enableProgressBar
                            ? _buildProgressBar()
                            : const SizedBox(),
                      if (_controlsConfiguration.enableMute)
                        _buildMoreButton()
                      else
                        const SizedBox(),
                      if (!_controlsConfiguration.enableMaximizeButton)
                        const SizedBox(width: 12.0),
                      if (_controlsConfiguration.enableFullscreen &&
                          _controlsConfiguration.enableMaximizeButton)
                        _buildExpandButton()
                      else
                        const SizedBox(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveWidget() {
    return Text(
      _betterPlayerController!.translations.controlsLive,
      style: TextStyle(
          color: _controlsConfiguration.liveTextColor,
          fontWeight: FontWeight.bold),
    );
  }

  Widget _buildExpandButton() {
    return Padding(
      padding: EdgeInsets.only(right: 16.0),
      child: BetterPlayerMaterialClickableWidget(
        onTap: _onExpandCollapse,
        child: AnimatedOpacity(
          opacity: controlsNotVisible ? 0.0 : 1.0,
          duration: _controlsConfiguration.controlsHideTime,
          child: Container(
            height: _controlsConfiguration.controlBarHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Center(
              child: Icon(
                _betterPlayerController!.isFullScreen
                    ? _controlsConfiguration.fullscreenDisableIcon
                    : _controlsConfiguration.fullscreenEnableIcon,
                size: 16,
                color: _betterPlayerController!.isFullScreen
                    ? _controlsConfiguration.iconsColor
                    : Colors.black87,
                shadows: [
                  Shadow(
                    blurRadius: 20,
                    color: Colors.grey.withOpacity(0.75),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHitArea() {
    if (!betterPlayerController!.controlsEnabled) {
      return const SizedBox();
    }
    return Container(
      child: Center(
        child: AnimatedOpacity(
          opacity: controlsNotVisible ? 0.0 : 1.0,
          duration: _controlsConfiguration.controlsHideTime,
          child: _buildMiddleRow(),
        ),
      ),
    );
  }

  Widget _buildMiddleRow() {
    return Container(
      // color: _controlsConfiguration.controlBarColor,
      width: double.infinity,
      height: double.infinity,
      child: _betterPlayerController?.isLiveStream() == true
          ? const SizedBox()
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                if (_controlsConfiguration.enableSkips)
                  Expanded(child: _buildSkipButton())
                else
                  const SizedBox(),
                Expanded(child: _buildReplayButton(_controller!)),
                if (_controlsConfiguration.enableSkips)
                  Expanded(child: _buildForwardButton())
                else
                  const SizedBox(),
              ],
            ),
    );
  }

  Widget _buildHitAreaClickableButton(
      {Widget? icon, required void Function() onClicked}) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 80.0, maxWidth: 80.0),
      child: BetterPlayerMaterialClickableWidget(
        onTap: onClicked,
        child: Align(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(48),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Stack(
                children: [icon!],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSkipButton() {
    return _buildHitAreaClickableButton(
      icon: Icon(
        _controlsConfiguration.skipBackIcon,
        size: _betterPlayerController!.isFullScreen ? 50 : 24,
        color: _controlsConfiguration.iconsColor,
        shadows: [
          Shadow(
            blurRadius: 20,
            color: Colors.grey.withOpacity(0.75),
          )
        ],
      ),
      onClicked: skipBack,
    );
  }

  Widget _buildForwardButton() {
    return _buildHitAreaClickableButton(
      icon: Icon(
        _controlsConfiguration.skipForwardIcon,
        size: _betterPlayerController!.isFullScreen ? 50 : 24,
        color: _controlsConfiguration.iconsColor,
        shadows: [
          Shadow(
            blurRadius: 20,
            color: Colors.grey.withOpacity(0.75),
          )
        ],
      ),
      onClicked: skipForward,
    );
  }

  Widget _buildReplayButton(VideoPlayerController controller) {
    final bool isFinished = isVideoFinished(_latestValue);
    return OnTapClick(
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              spreadRadius: 5,
            ),
          ],
          color: Color(0xFFFFC947),
          shape: BoxShape.circle,
        ),
        child: isFinished
            ? Icon(
                Icons.replay,
                size: 42,
                color: _controlsConfiguration.iconsColor,
              )
            : Icon(
                controller.value.isPlaying
                    ? _controlsConfiguration.pauseIcon
                    : _controlsConfiguration.playIcon,
                size: 42,
                color: _controlsConfiguration.iconsColor,
              ),
      ),
      onTap: () {
        if (isFinished) {
          if (_latestValue != null && _latestValue!.isPlaying) {
            if (_displayTapped) {
              changePlayerControlsNotVisible(true);
            } else {
              cancelAndRestartTimer();
            }
          } else {
            _onPlayPause();
            changePlayerControlsNotVisible(true);
          }
        } else {
          _onPlayPause();
        }
      },
    );
  }

  Widget _buildNextVideoWidget() {
    return StreamBuilder<int?>(
      stream: _betterPlayerController!.nextVideoTimeStream,
      builder: (context, snapshot) {
        final time = snapshot.data;
        if (time != null && time > 0) {
          return BetterPlayerMaterialClickableWidget(
            onTap: () {
              _betterPlayerController!.playNextVideo();
            },
            child: Align(
              alignment: Alignment.bottomRight,
              child: Container(
                margin: EdgeInsets.only(
                    bottom: _controlsConfiguration.controlBarHeight + 20,
                    right: 24),
                decoration: BoxDecoration(
                  color: _controlsConfiguration.controlBarColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    "${_betterPlayerController!.translations.controlsNextVideoIn} $time...",
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          );
        } else {
          return const SizedBox();
        }
      },
    );
  }

  Widget _buildMuteButton(
    VideoPlayerController? controller,
  ) {
    return OnTapClick(
      onTap: () {
        cancelAndRestartTimer();
        if (_latestValue!.volume == 0) {
          _betterPlayerController!.setVolume(_latestVolume ?? 0.5);
        } else {
          _latestVolume = controller!.value.volume;
          _betterPlayerController!.setVolume(0.0);
        }
      },
      child: AnimatedOpacity(
        opacity: controlsNotVisible ? 0.0 : 1.0,
        duration: _controlsConfiguration.controlsHideTime,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(50),
          child: new BackdropFilter(
            filter: new ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.transparent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    blurRadius: 20,
                    color: Colors.grey.withOpacity(0.75),
                  )
                ],
              ),
              child: Icon(
                (_latestValue != null && _latestValue!.volume > 0)
                    ? _controlsConfiguration.muteIcon
                    : _controlsConfiguration.unMuteIcon,
                size: 16,
                color: _controlsConfiguration.iconsColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayPause(VideoPlayerController controller) {
    return BetterPlayerMaterialClickableWidget(
      key: const Key("better_player_material_controls_play_pause_button"),
      onTap: _onPlayPause,
      child: Container(
        height: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Icon(
          controller.value.isPlaying
              ? _controlsConfiguration.pauseIcon
              : _controlsConfiguration.playIcon,
          color: _controlsConfiguration.iconsColor,
        ),
      ),
    );
  }

  Widget _buildPosition() {
    final position =
        _latestValue != null ? _latestValue!.position : Duration.zero;
    final duration = _latestValue != null && _latestValue!.duration != null
        ? _latestValue!.duration!
        : Duration.zero;

    return Padding(
      padding: _controlsConfiguration.enablePlayPause
          ? const EdgeInsets.symmetric(horizontal: 15)
          : const EdgeInsets.symmetric(horizontal: 22),
      child: RichText(
        text: TextSpan(
            text: BetterPlayerUtils.formatDuration(position),
            style: TextStyle(
              fontSize: 10.0,
              color: _controlsConfiguration.textColor,
              decoration: TextDecoration.none,
            ),
            children: <TextSpan>[
              TextSpan(
                text: ' / ${BetterPlayerUtils.formatDuration(duration)}',
                style: TextStyle(
                  fontSize: 10.0,
                  color: _controlsConfiguration.textColor,
                  decoration: TextDecoration.none,
                ),
              )
            ]),
      ),
    );
  }

  @override
  void cancelAndRestartTimer() {
    _hideTimer?.cancel();
    _startHideTimer();

    changePlayerControlsNotVisible(false);
    _displayTapped = true;
  }

  Future<void> _initialize() async {
    _controller!.addListener(_updateState);

    _updateState();

    if ((_controller!.value.isPlaying) ||
        _betterPlayerController!.betterPlayerConfiguration.autoPlay) {
      _startHideTimer();
    }

    if (_controlsConfiguration.showControlsOnInitialize) {
      _initTimer = Timer(const Duration(milliseconds: 200), () {
        changePlayerControlsNotVisible(false);
      });
    }

    _controlsVisibilityStreamSubscription =
        _betterPlayerController!.controlsVisibilityStream.listen((state) {
      changePlayerControlsNotVisible(!state);
      if (!controlsNotVisible) {
        cancelAndRestartTimer();
      }
    });
  }

  void _onExpandCollapse() {
    changePlayerControlsNotVisible(true);
    _betterPlayerController!.toggleFullScreen();
    _showAfterExpandCollapseTimer =
        Timer(_controlsConfiguration.controlsHideTime, () {
      setState(() {
        cancelAndRestartTimer();
      });
    });
  }

  void _onPlayPause() {
    bool isFinished = false;

    if (_latestValue?.position != null && _latestValue?.duration != null) {
      isFinished = _latestValue!.position >= _latestValue!.duration!;
    }

    if (_controller!.value.isPlaying) {
      changePlayerControlsNotVisible(false);
      _hideTimer?.cancel();
      _betterPlayerController!.pause();
    } else {
      cancelAndRestartTimer();

      if (!_controller!.value.initialized) {
      } else {
        if (isFinished) {
          _betterPlayerController!.seekTo(const Duration());
        }
        _betterPlayerController!.play();
        _betterPlayerController!.cancelNextVideoTimer();
      }
    }
  }

  void _startHideTimer() {
    if (_betterPlayerController!.controlsAlwaysVisible) {
      return;
    }
    _hideTimer = Timer(const Duration(milliseconds: 3000), () {
      changePlayerControlsNotVisible(true);
    });
  }

  void _updateState() {
    if (mounted) {
      if (!controlsNotVisible ||
          isVideoFinished(_controller!.value) ||
          _wasLoading ||
          isLoading(_controller!.value)) {
        setState(() {
          _latestValue = _controller!.value;
          if (isVideoFinished(_latestValue) &&
              _betterPlayerController?.isLiveStream() == false) {
            changePlayerControlsNotVisible(false);
          }
        });
      }
    }
  }

  Widget _buildProgressBar() {
    return Expanded(
      // flex: 40,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: BetterPlayerMaterialVideoProgressBar(
          _controller,
          _betterPlayerController,
          onDragStart: () {
            _hideTimer?.cancel();
          },
          onDragEnd: () {
            _startHideTimer();
          },
          onTapDown: () {
            cancelAndRestartTimer();
          },
          colors: BetterPlayerProgressColors(
              playedColor: _controlsConfiguration.progressBarPlayedColor,
              handleColor: _controlsConfiguration.progressBarHandleColor,
              bufferedColor: _controlsConfiguration.progressBarBufferedColor,
              backgroundColor:
                  _controlsConfiguration.progressBarBackgroundColor),
        ),
      ),
    );
  }

  void _onPlayerHide() {
    _betterPlayerController!.toggleControlsVisibility(!controlsNotVisible);
    widget.onControlsVisibilityChanged(!controlsNotVisible);
  }

  Widget? _buildLoadingWidget() {
    if (_controlsConfiguration.loadingWidget != null) {
      return Container(
        color: _controlsConfiguration.controlBarColor,
        child: _controlsConfiguration.loadingWidget,
      );
    }

    return CircularProgressIndicator(
      valueColor:
          AlwaysStoppedAnimation<Color>(_controlsConfiguration.loadingColor),
    );
  }
}
