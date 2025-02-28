/*
 * Copyright (C) 2019 Alibaba Inc. All rights reserved.
 * Author: Kraken Team.
 */

import 'dart:ffi';
import 'dart:async';
import 'dart:io';
import 'package:kraken/bridge.dart';
import 'package:flutter/rendering.dart';
import 'package:kraken/dom.dart';
import 'package:kraken/rendering.dart';
import 'package:kraken/css.dart';
import 'package:path_provider/path_provider.dart';
import 'camera.dart';

const String CAMERA_PREVIEW = 'CAMERA-PREVIEW';

final Map<String, dynamic> _defaultStyle = {
  DISPLAY: BLOCK,
  WIDTH: ELEMENT_DEFAULT_WIDTH,
  HEIGHT: ELEMENT_DEFAULT_HEIGHT,
};

bool camerasDetected = false;
List<CameraDescription> cameras = [];

Future<CameraDescription?> detectCamera(String? lens) async {
  if (lens == null) lens = 'back';

  if (!camerasDetected) {
    try {
      // Obtain a list of the available cameras on the device.
      cameras = await availableCameras();
    } on CameraException catch (err) {
      // No available camera devices, need to fallback.
      print('Camera Exception $err');
    }
    camerasDetected = true;
  }

  for (CameraDescription description in cameras) {
    if (description.lensDirection == parseCameraLensDirection(lens)) {
      return description;
    }
  }

  return null;
}

class CameraPreviewElement extends Element {
  CameraPreviewElement(int targetId, Pointer<NativeEventTarget> nativePtr, ElementManager elementManager)
      : super(targetId, nativePtr, elementManager, defaultStyle: _defaultStyle, isIntrinsicBox: true);


  static const String WIDTH = 'width';
  static const String HEIGHT = 'height';

  double? _propertyWidth;
  double? _propertyHeight;
  double? get width => renderStyle.width.isAuto ? _propertyWidth : renderStyle.width.computedValue;
  double? get height => renderStyle.height.isAuto ? _propertyHeight : renderStyle.height.computedValue;
  Size get size => Size(width!, height!);

  @override
  void didAttachRenderer() {
    super.didAttachRenderer();

    sizedBox = RenderConstrainedBox(additionalConstraints: BoxConstraints.loose(size));
    addChild(sizedBox);
  }

  bool enableAudio = false;
  late RenderConstrainedBox sizedBox;
  CameraDescription? cameraDescription;
  TextureBox? renderTextureBox;
  CameraController? controller;
  List<VoidCallback> detectedFunc = [];

  void _invokeReady() {
    for (VoidCallback fn in detectedFunc) fn();
    detectedFunc = [];
  }

  @override
  void dispose() {
    super.dispose();
    controller!.dispose();
  }

  double get aspectRatio {
    double _aspectRatio = 1.0;
    if (width != null && height != null) {
      _aspectRatio = width! / height!;
    } else if (controller != null) {
      _aspectRatio = controller!.value.aspectRatio;
    }

    // sensorOrientation can be [0, 90, 180, 270],
    // while 90 / 270 is reverted to width and height.
    if ((cameraDescription?.sensorOrientation ?? 0 / 90) % 2 == 1) {
      _aspectRatio = 1 / _aspectRatio;
    }
    return _aspectRatio;
  }

  ResolutionPreset? _resolutionPreset;
  ResolutionPreset? get resolutionPreset => _resolutionPreset;
  set resolutionPreset(ResolutionPreset? value) {
    if (_resolutionPreset != value) {
      _resolutionPreset = value;
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (cameraDescription != null) {
      TextureBox textureBox = await createCameraTextureBox(cameraDescription);
      _invokeReady();
      sizedBox.child = RenderAspectRatio(aspectRatio: aspectRatio, child: textureBox);
    }
  }

  void _initCameraWithLens(String? lens) async {
    cameraDescription = await detectCamera(lens);
    if (cameraDescription == null) {
      _invokeReady();
      sizedBox.child = _buildFallbackView('Camera Fallback View');
    } else {
      await _initCamera();
    }
  }

  RenderBox _buildFallbackView(String description) {
    assert(description != null);

    TextStyle textStyle = TextStyle(
      color: Color(0xFF000000),
      backgroundColor: Color(0xFFFFFFFF)
    );
    return RenderFallbackViewBox(
      child: KrakenRenderParagraph(
        TextSpan(text: description, style: textStyle),
        textDirection: TextDirection.ltr,
      ),
    );
  }

  Future<TextureBox> createCameraTextureBox(CameraDescription? cameraDescription) async {
    this.cameraDescription = cameraDescription;
    await _createCameraController();
    return TextureBox(textureId: controller!.textureId!);
  }

  Future<void> _createCameraController({
    ResolutionPreset resoluton = ResolutionPreset.medium,
    bool enableAudio = false,
  }) async {
    if (controller != null) {
      await controller!.dispose();
    }
    controller = CameraController(
      cameraDescription,
      resoluton,
      enableAudio: enableAudio,
    );

    // If the controller is updated then update the UI.
    controller!.addListener(() {
      if (isConnected) {
        renderBoxModel!.markNeedsPaint();
      }
      if (controller!.value.hasError) {
        print('Camera error ${controller!.value.errorDescription}');
      }
    });

    try {
      await controller!.initialize();
    } on CameraException catch (err) {
      print('Error while initializing camera controller: $err');
    }
  }

  @override
  void setProperty(String key, dynamic value) async {
    super.setProperty(key, value);
    _setProperty(key, value);
  }

  @override
  getProperty(String key) {
    switch(key) {
      case 'takePicture':
        return (List<dynamic> argv) async => await _takePicture(argv[0]);
    }
    return super.getProperty(key);
  }

  void _setProperty(String key, dynamic value) {
    if (key == 'resolution-preset') {
      resolutionPreset = getResolutionPreset(value);
    } else if (key == WIDTH) {
      _propertyWidth = CSSNumber.parseNumber(value);
      if (sizedBox != null) {
        sizedBox!.additionalConstraints = BoxConstraints.tight(size);
      }
    } else if (key == HEIGHT) {
      _propertyHeight = CSSNumber.parseNumber(value);
      if (sizedBox != null) {
        sizedBox!.additionalConstraints = BoxConstraints.tight(size);
      }
    } else if (key == 'lens') {
      _initCameraWithLens(value);
    } else if (key == 'sensor-orientation') {
      _updateSensorOrientation(value);
    }
  }

  Future<void> _takePicture(value) async {
    Directory tempDir = await getTemporaryDirectory();
    String tempPath = tempDir.path;
    await controller!.takePicture(tempPath + '/' + value);
  }

  void _updateSensorOrientation(value) async {
    int? sensorOrientation = int.tryParse(value.toString());
    cameraDescription = cameraDescription!.copyWith(sensorOrientation: sensorOrientation);
    await _initCamera();
  }
}

/// Returns the resolution preset from string.
ResolutionPreset getResolutionPreset(String? preset) {
  switch (preset) {
    case 'max':
      return ResolutionPreset.max;
    case 'ultraHigh':
      return ResolutionPreset.ultraHigh;
    case 'veryHigh':
      return ResolutionPreset.veryHigh;
    case 'high':
      return ResolutionPreset.high;
    case 'low':
      return ResolutionPreset.low;
    case 'medium':
    default:
      return ResolutionPreset.medium;
  }
}
