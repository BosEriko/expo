#import <AVFoundation/AVFoundation.h>

#import <EXCamera/EXCamera.h>
#import <EXCamera/EXCameraUtils.h>
#import <EXCamera/EXImageUtils.h>
#import <EXCamera/EXCameraManager.h>
#import <EXCamera/EXFileSystem.h>
#import <EXCamera/EXFaceDetector.h>
#import <EXCamera/EXPermissions.h>
#import <EXCamera/EXLifecycleManager.h>
#import <EXCore/EXUtil.h>

@interface EXCamera ()

@property (nonatomic, weak) id<EXFileSystem> fileSystem;
@property (nonatomic, weak) EXModuleRegistry *moduleRegistry;
@property (nonatomic, strong) id<EXFaceDetectorManager> faceDetectorManager;
@property (nonatomic, weak) id<EXPermissions> permissionsManager;
@property (nonatomic, weak) id<EXLifecycleManager> lifecycleManager;

@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;

@property (nonatomic, strong) EXPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) EXPromiseRejectBlock videoRecordedReject;

@property (nonatomic, copy) EXDirectEventBlock onCameraReady;
@property (nonatomic, copy) EXDirectEventBlock onMountError;
@property (nonatomic, copy) EXDirectEventBlock onBarCodeRead;
@property (nonatomic, copy) EXDirectEventBlock onFacesDetected;

@end

@implementation EXCamera

static NSDictionary *defaultFaceDetectorOptions = nil;

- (id)initWithModuleRegistry:(EXModuleRegistry *)moduleRegistry
{
  if ((self = [super init])) {
    self.moduleRegistry = moduleRegistry;
    self.session = [AVCaptureSession new];
    self.sessionQueue = dispatch_queue_create("cameraQueue", DISPATCH_QUEUE_SERIAL);
    self.faceDetectorManager = [self createFaceDetectorManager];
    self.lifecycleManager = [moduleRegistry getModuleForName:@"LifecycleManager" downcastedTo:@protocol(EXLifecycleManager) exception:nil];
    self.fileSystem = [moduleRegistry getModuleForName:@"ExponentFileSystem" downcastedTo:@protocol(EXFileSystem) exception:nil];
    self.permissionsManager = [moduleRegistry getModuleForName:@"Permissions" downcastedTo:@protocol(EXPermissions) exception:nil];
#if !(TARGET_IPHONE_SIMULATOR)
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.needsDisplayOnBoundsChange = YES;
#endif
    self.paused = NO;
    [self changePreviewOrientation:[UIApplication sharedApplication].statusBarOrientation];
    [self initializeCaptureSessionInput];
    [self startSession];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationChanged:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [_lifecycleManager registerAppLifecycleListener:self];
  }
  return self;
}

- (void)onReady:(NSDictionary *)event
{
  if (_onCameraReady) {
    _onCameraReady(nil);
  }
}

- (void)onMountingError:(NSDictionary *)event
{
  if (_onMountError) {
    _onMountError(event);
  }
}

- (void)onCodeRead:(NSDictionary *)event
{
  if (_onBarCodeRead) {
    _onBarCodeRead(event);
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  self.previewLayer.frame = self.bounds;
  [self setBackgroundColor:[UIColor blackColor]];
  [self.layer insertSublayer:self.previewLayer atIndex:0];
}

//- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
//{
//  [self insertSubview:view atIndex:atIndex + 1];
//  [super insertReactSubview:view atIndex:atIndex];
//  return;
//}
//
//- (void)removeReactSubview:(UIView *)subview
//{
//  [subview removeFromSuperview];
//  [super removeReactSubview:subview];
//  return;
//}

- (void)removeFromSuperview
{
  [_lifecycleManager unregisterAppLifecycleListener:self];
  [self stopSession];
  [super removeFromSuperview];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
  
}

-(void)updateType
{
  dispatch_async(self.sessionQueue, ^{
    [self initializeCaptureSessionInput];
    if (!self.session.isRunning) {
      [self startSession];
    }
  });
}

- (void)updateFlashMode
{
  AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
  NSError *error = nil;
  
  if (self.flashMode == EXCameraFlashModeTorch) {
    if (![device hasTorch])
      return;
    if (![device lockForConfiguration:&error]) {
      if (error) {
        EXLogError(@"%s: %@", __func__, error);
      }
      return;
    }
    if (device.hasTorch && [device isTorchModeSupported:AVCaptureTorchModeOn])
    {
      NSError *error = nil;
      if ([device lockForConfiguration:&error]) {
        [device setFlashMode:AVCaptureFlashModeOff];
        [device setTorchMode:AVCaptureTorchModeOn];
        [device unlockForConfiguration];
      } else {
        if (error) {
          EXLogError(@"%s: %@", __func__, error);
        }
      }
    }
  } else {
    if (![device hasFlash])
      return;
    if (![device lockForConfiguration:&error]) {
      if (error) {
        EXLogError(@"%s: %@", __func__, error);
      }
      return;
    }
    if (device.hasFlash && [device isFlashModeSupported:self.flashMode])
    {
      NSError *error = nil;
      if ([device lockForConfiguration:&error]) {
        if ([device isTorchModeSupported:AVCaptureTorchModeOff]) {
          [device setTorchMode:AVCaptureTorchModeOff];
        }
        [device setFlashMode:self.flashMode];
        [device unlockForConfiguration];
      } else {
        if (error) {
          EXLogError(@"%s: %@", __func__, error);
        }
      }
    }
  }
  
  [device unlockForConfiguration];
}

- (void)updateFocusMode
{
  AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
  NSError *error = nil;
  
  if (![device lockForConfiguration:&error]) {
    if (error) {
      EXLogError(@"%s: %@", __func__, error);
    }
    return;
  }
  
  if ([device isFocusModeSupported:self.autoFocus]) {
    if ([device lockForConfiguration:&error]) {
      [device setFocusMode:self.autoFocus];
    } else {
      if (error) {
        EXLogError(@"%s: %@", __func__, error);
      }
    }
  }
  
  [device unlockForConfiguration];
}

- (void)updateFocusDepth
{
  AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
  NSError *error = nil;
  
  if (device.focusMode != EXCameraAutoFocusOff) {
    return;
  }
  
  if (@available(iOS 10.0, *)) {
    if ([device isLockingFocusWithCustomLensPositionSupported]) {
      if (![device lockForConfiguration:&error]) {
        if (error) {
          EXLogError(@"%s: %@", __func__, error);
        }
        return;
      }

      __weak __typeof__(device) weakDevice = device;
      [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
        [weakDevice unlockForConfiguration];
      }];
      return;
    }
  }
  
  EXLogWarn(@"%s: Setting focusDepth isn't supported for this camera device", __func__);
  return;
}

- (void)updateZoom {
  AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
  NSError *error = nil;
  
  if (![device lockForConfiguration:&error]) {
    if (error) {
      EXLogError(@"%s: %@", __func__, error);
    }
    return;
  }
  
  device.videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 1.0) * self.zoom + 1.0;
  
  [device unlockForConfiguration];
}

- (void)updateWhiteBalance
{
  AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
  NSError *error = nil;
  
  if (![device lockForConfiguration:&error]) {
    if (error) {
      EXLogError(@"%s: %@", __func__, error);
    }
    return;
  }
  
  if (self.whiteBalance == EXCameraWhiteBalanceAuto) {
    [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
    [device unlockForConfiguration];
  } else {
    AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
      .temperature = [EXCameraUtils temperatureForWhiteBalance:self.whiteBalance],
      .tint = 0,
    };
    AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
    __weak __typeof__(device) weakDevice = device;
    if ([device lockForConfiguration:&error]) {
      [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
        [weakDevice unlockForConfiguration];
      }];
    } else {
      if (error) {
        EXLogError(@"%s: %@", __func__, error);
      }
    }
  }
  
  [device unlockForConfiguration];
}

- (void)setFaceDetecting:(BOOL)faceDetecting
{
  if (_faceDetectorManager) {
    [_faceDetectorManager setIsEnabled:faceDetecting];
  }
}

- (void)updateFaceDetectorSettings:(NSDictionary *)settings
{
  if (_faceDetectorManager) {
    [_faceDetectorManager updateSettings:settings];
  }
}

- (void)takePicture:(NSDictionary *)options resolve:(EXPromiseResolveBlock)resolve reject:(EXPromiseRejectBlock)reject
{
  AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
  [connection setVideoOrientation:[EXCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];
  __weak EXCamera *weakSelf = self;
  [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
    __strong EXCamera *strongSelf = weakSelf;
    if (strongSelf) {
      if (imageSampleBuffer && !error) {
        NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
        
        UIImage *takenImage = [UIImage imageWithData:imageData];
        
        CGRect frame = [strongSelf.previewLayer metadataOutputRectOfInterestForRect:self.frame];
        CGImageRef takenCGImage = takenImage.CGImage;
        size_t width = CGImageGetWidth(takenCGImage);
        size_t height = CGImageGetHeight(takenCGImage);
        CGRect cropRect = CGRectMake(frame.origin.x * width, frame.origin.y * height, frame.size.width * width, frame.size.height * height);
        takenImage = [EXImageUtils cropImage:takenImage toRect:cropRect];
        
        NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
        float quality = [options[@"quality"] floatValue];
        NSData *takenImageData = UIImageJPEGRepresentation(takenImage, quality);
        if (!strongSelf.fileSystem) {
          reject(@"E_IMAGE_SAVE_FAILED", @"No file system module", nil);
          return;
        }
        NSString *path = [strongSelf.fileSystem generatePathInDirectory:[_fileSystem.cachesDirectory stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
        
        response[@"uri"] = [EXImageUtils writeImage:takenImageData toPath:path];
        response[@"width"] = @(takenImage.size.width);
        response[@"height"] = @(takenImage.size.height);
        
        if ([options[@"base64"] boolValue]) {
          response[@"base64"] = [takenImageData base64EncodedStringWithOptions:0];
        }
        
        if ([options[@"exif"] boolValue]) {
          int imageRotation;
          switch (takenImage.imageOrientation) {
            case UIImageOrientationLeft:
              imageRotation = 90;
              break;
            case UIImageOrientationRight:
              imageRotation = -90;
              break;
            case UIImageOrientationDown:
              imageRotation = 180;
              break;
            default:
              imageRotation = 0;
          }
          [EXImageUtils updatePhotoMetadata:imageSampleBuffer withAdditionalData:@{ @"Orientation": @(imageRotation) } inResponse:response]; // TODO
        }
        
        resolve(response);
      } else {
        reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
      }
    } else {
      reject(@"E_IMAGE_CAPTURE_FAILED", @"Camera view has been unmounted before image had been captured", nil);
    }
  }];
}

- (void)record:(NSDictionary *)options resolve:(EXPromiseResolveBlock)resolve reject:(EXPromiseRejectBlock)reject
{
  if (_movieFileOutput == nil) {
    // At the time of writing AVCaptureMovieFileOutput and AVCaptureVideoDataOutput (> GMVDataOutput)
    // cannot coexist on the same AVSession (see: https://stackoverflow.com/a/4986032/1123156).
    // We stop face detection here and restart it in when AVCaptureMovieFileOutput finishes recording.
    if (_faceDetectorManager) {
      [_faceDetectorManager stopFaceDetection];
    }
    [self setupMovieFileCapture];
  }
  
  if (self.movieFileOutput != nil && !self.movieFileOutput.isRecording && _videoRecordedResolve == nil && _videoRecordedReject == nil) {
    if (options[@"maxDuration"]) {
      Float64 maxDuration = [options[@"maxDuration"] floatValue];
      self.movieFileOutput.maxRecordedDuration = CMTimeMakeWithSeconds(maxDuration, 30);
    }
    
    if (options[@"maxFileSize"]) {
      self.movieFileOutput.maxRecordedFileSize = [options[@"maxFileSize"] integerValue];
    }
    
    if (options[@"quality"]) {
      [self updateSessionPreset:[EXCameraUtils captureSessionPresetForVideoResolution:(EXCameraVideoResolution)[options[@"quality"] integerValue]]];
    }
    
    [self updateSessionAudioIsMuted:!!options[@"mute"]];
    
    AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:[EXCameraUtils videoOrientationForInterfaceOrientation:[[UIApplication sharedApplication] statusBarOrientation]]];
    
    __weak EXCamera *weakSelf = self;
    dispatch_async(self.sessionQueue, ^{
      __strong EXCamera *strongSelf = weakSelf;
      if (!strongSelf) {
        reject(@"E_IMAGE_SAVE_FAILED", @"Camera view has been unmounted.", nil);
        return;
      }
      if (!strongSelf.fileSystem) {
        reject(@"E_IMAGE_SAVE_FAILED", @"No file system module", nil);
        return;
      }
      NSString *directory = [strongSelf.fileSystem.cachesDirectory stringByAppendingPathComponent:@"Camera"];
      NSString *path = [strongSelf.fileSystem generatePathInDirectory:directory withExtension:@".mov"];
      NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:path];
      [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
      self.videoRecordedResolve = resolve;
      self.videoRecordedReject = reject;
    });
  }
}

- (void)stopRecording
{
  [self.movieFileOutput stopRecording];
}

- (void)startSession
{
#if TARGET_IPHONE_SIMULATOR
  return;
#endif
  NSDictionary *cameraPermissions = [_permissionsManager getPermissionsForResource:@"camera"];
  if (![cameraPermissions[@"status"] isEqualToString:@"granted"]) {
    [self onMountingError:@{@"message": @"Camera permissions not granted - component could not be rendered."}];
    return;
  }
  __weak EXCamera *weakSelf = self;
  dispatch_async(self.sessionQueue, ^{
    __strong EXCamera *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    if (strongSelf.presetCamera == AVCaptureDevicePositionUnspecified) {
      return;
    }
    
    AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
    if ([strongSelf.session canAddOutput:stillImageOutput]) {
      stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
      [strongSelf.session addOutput:stillImageOutput];
      [stillImageOutput setHighResolutionStillImageOutputEnabled:YES];
      strongSelf.stillImageOutput = stillImageOutput;
    }
    
    if (strongSelf.faceDetectorManager) {
      [strongSelf.faceDetectorManager maybeStartFaceDetectionOnSession:strongSelf.session withPreviewLayer:strongSelf.previewLayer];
    }
    [strongSelf setupOrDisableBarcodeScanner];
    
    
    [strongSelf setRuntimeErrorHandlingObserver:
     [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:strongSelf.session queue:nil usingBlock:^(NSNotification *note) {
      __strong EXCamera *innerStrongSelf = weakSelf;
      if (innerStrongSelf) {
        dispatch_async(innerStrongSelf.sessionQueue, ^{
          __strong EXCamera *innerInnerStrongSelf = weakSelf;
          if (innerInnerStrongSelf) {
            // Manually restarting the session since it must
            // have been stopped due to an error.
            [strongSelf.session startRunning];
            [strongSelf onReady:nil];
          }
        });
      }
    }]];
    
    [strongSelf.session startRunning];
    [strongSelf onReady:nil];
  });
}

- (void)stopSession
{
#if TARGET_IPHONE_SIMULATOR
  return;
#endif
  __weak EXCamera *weakSelf = self;
  dispatch_async(self.sessionQueue, ^{
    __strong EXCamera *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    if (strongSelf.faceDetectorManager) {
      [strongSelf.faceDetectorManager stopFaceDetection];
    }
    [strongSelf.previewLayer removeFromSuperlayer];
    [strongSelf.session commitConfiguration];
    [strongSelf.session stopRunning];
    for (AVCaptureInput *input in strongSelf.session.inputs) {
      [strongSelf.session removeInput:input];
    }
    
    for (AVCaptureOutput *output in strongSelf.session.outputs) {
      [strongSelf.session removeOutput:output];
    }
  });
}

- (void)initializeCaptureSessionInput
{
  if (self.videoCaptureDeviceInput.device.position == self.presetCamera) {
    return;
  }
  __block UIInterfaceOrientation interfaceOrientation;
  
  [EXUtil performSynchronouslyOnMainThread:^{
    interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
  }];
  AVCaptureVideoOrientation orientation = [EXCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];
  
  __weak EXCamera *weakSelf = self;
  dispatch_async(self.sessionQueue, ^{
    __strong EXCamera *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    [strongSelf.session beginConfiguration];
    
    NSError *error = nil;
    AVCaptureDevice *captureDevice = [EXCameraUtils deviceWithMediaType:AVMediaTypeVideo preferringPosition:strongSelf.presetCamera];
    AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];
    
    if (error || captureDeviceInput == nil) {
      EXLogError(@"%s: %@", __func__, error);
      return;
    }
    
    [strongSelf.session removeInput:self.videoCaptureDeviceInput];
    if ([strongSelf.session canAddInput:captureDeviceInput]) {
      [strongSelf.session addInput:captureDeviceInput];
      
      strongSelf.videoCaptureDeviceInput = captureDeviceInput;
      [strongSelf updateFlashMode];
      [strongSelf updateZoom];
      [strongSelf updateFocusMode];
      [strongSelf updateFocusDepth];
      [strongSelf updateWhiteBalance];
      [strongSelf.previewLayer.connection setVideoOrientation:orientation];
      [strongSelf _updateMetadataObjectsToRecognize];
    }
    
    [strongSelf.session commitConfiguration];
  });
}

#pragma mark - internal

- (void)updateSessionPreset:(NSString *)preset
{
#if !(TARGET_IPHONE_SIMULATOR)
  if (preset) {
    __weak EXCamera *weakSelf = self;
    dispatch_async(self.sessionQueue, ^{
      __strong EXCamera *strongSelf = weakSelf;
      if (strongSelf) {
        [strongSelf.session beginConfiguration];
        if ([strongSelf.session canSetSessionPreset:preset]) {
          strongSelf.session.sessionPreset = preset;
        }
        [strongSelf.session commitConfiguration];
      }
    });
  }
#endif
}

- (void)updateSessionAudioIsMuted:(BOOL)isMuted
{
  __weak EXCamera *weakSelf = self;
  dispatch_async(self.sessionQueue, ^{
    __strong EXCamera *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf.session beginConfiguration];
      
      for (AVCaptureDeviceInput* input in [strongSelf.session inputs]) {
        if ([input.device hasMediaType:AVMediaTypeAudio]) {
          if (isMuted) {
            [strongSelf.session removeInput:input];
          }
          [strongSelf.session commitConfiguration];
          return;
        }
      }
      
      if (!isMuted) {
        NSError *error = nil;
        
        AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];
        
        if (error || audioDeviceInput == nil) {
          EXLogWarn(@"%s: %@", __func__, error);
          return;
        }
        
        if ([strongSelf.session canAddInput:audioDeviceInput]) {
          [strongSelf.session addInput:audioDeviceInput];
        }
      }
      
      [strongSelf.session commitConfiguration];
    }
  });
}

- (void)onAppForegrounded
{
  if (![self.session isRunning] && [self isSessionPaused]) {
    self.paused = NO;
    __weak EXCamera *weakSelf = self;
    dispatch_async(self.sessionQueue, ^{
      __strong EXCamera *strongSelf = weakSelf;
      if (strongSelf) {
        [strongSelf.session startRunning];
      }
    });
  }
}

- (void)onAppBackgrounded
{
  if ([self.session isRunning] && ![self isSessionPaused]) {
    self.paused = YES;
    __weak EXCamera *weakSelf = self;
    dispatch_async(self.sessionQueue, ^{
      __strong EXCamera *strongSelf = weakSelf;
      if (strongSelf) {
        [strongSelf.session stopRunning];
      }
    });
  }
}

- (void)orientationChanged:(NSNotification *)notification
{
  UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
  [self changePreviewOrientation:orientation];
}

- (void)changePreviewOrientation:(UIInterfaceOrientation)orientation
{
  __weak EXCamera *weakSelf = self;
  AVCaptureVideoOrientation videoOrientation = [EXCameraUtils videoOrientationForInterfaceOrientation:orientation];
  [EXUtil performSynchronouslyOnMainThread:^{
    __strong EXCamera *strongSelf = weakSelf;
    if (strongSelf && strongSelf.previewLayer.connection.isVideoOrientationSupported) {
      [strongSelf.previewLayer.connection setVideoOrientation:videoOrientation];
    }
  }];
}

# pragma mark - AVCaptureMetadataOutput

- (void)setupOrDisableBarcodeScanner
{
  [self _setupOrDisableMetadataOutput];
  [self _updateMetadataObjectsToRecognize];
}

- (void)_setupOrDisableMetadataOutput
{
  if ([self isReadingBarCodes] && (_metadataOutput == nil || ![self.session.outputs containsObject:_metadataOutput])) {
    AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
    if ([self.session canAddOutput:metadataOutput]) {
      [metadataOutput setMetadataObjectsDelegate:self queue:self.sessionQueue];
      [self.session addOutput:metadataOutput];
      self.metadataOutput = metadataOutput;
    }
  } else if (_metadataOutput != nil && ![self isReadingBarCodes]) {
    [self.session removeOutput:_metadataOutput];
    _metadataOutput = nil;
  }
}

- (void)_updateMetadataObjectsToRecognize
{
  if (_metadataOutput == nil) {
    return;
  }
  
  NSArray<AVMetadataObjectType> *availableRequestedObjectTypes = [[NSArray alloc] init];
  NSArray<AVMetadataObjectType> *requestedObjectTypes = [NSArray arrayWithArray:self.barCodeTypes];
  NSArray<AVMetadataObjectType> *availableObjectTypes = _metadataOutput.availableMetadataObjectTypes;
  
  for(AVMetadataObjectType objectType in requestedObjectTypes) {
    if ([availableObjectTypes containsObject:objectType]) {
      availableRequestedObjectTypes = [availableRequestedObjectTypes arrayByAddingObject:objectType];
    }
  }
  
  [_metadataOutput setMetadataObjectTypes:availableRequestedObjectTypes];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
  for(AVMetadataObject *metadata in metadataObjects) {
    if([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
      AVMetadataMachineReadableCodeObject *codeMetadata = (AVMetadataMachineReadableCodeObject *) metadata;
      for (id barcodeType in self.barCodeTypes) {
        if ([metadata.type isEqualToString:barcodeType]) {
          
          NSDictionary *event = @{
                                  @"type" : codeMetadata.type,
                                  @"data" : codeMetadata.stringValue
                                  };
          
          [self onCodeRead:event];
        }
      }
    }
  }
}

# pragma mark - AVCaptureMovieFileOutput

- (void)setupMovieFileCapture
{
  AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
  
  if ([self.session canAddOutput:movieFileOutput]) {
    [self.session addOutput:movieFileOutput];
    self.movieFileOutput = movieFileOutput;
  }
}

- (void)cleanupMovieFileCapture
{
  if ([_session.outputs containsObject:_movieFileOutput]) {
    [_session removeOutput:_movieFileOutput];
    _movieFileOutput = nil;
  }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
  BOOL success = YES;
  if ([error code] != noErr) {
    NSNumber *value = [[error userInfo] objectForKey:AVErrorRecordingSuccessfullyFinishedKey];
    if (value) {
      success = [value boolValue];
    }
  }
  if (success && self.videoRecordedResolve != nil) {
    self.videoRecordedResolve(@{ @"uri": outputFileURL.absoluteString });
  } else if (self.videoRecordedReject != nil) {
    self.videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", error);
  }
  self.videoRecordedResolve = nil;
  self.videoRecordedReject = nil;
  
  [self cleanupMovieFileCapture];
  // If face detection has been running prior to recording to file
  // we reenable it here (see comment in -record).
  if (_faceDetectorManager) {
    [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
  }
  
  if (self.session.sessionPreset != AVCaptureSessionPresetHigh) {
    [self updateSessionPreset:AVCaptureSessionPresetHigh];
  }
}

# pragma mark - Face detector

- (id)createFaceDetectorManager
{
  id <EXFaceDetectorManager> faceDetector = [_moduleRegistry getModuleForName:@"FaceDetector" downcastedTo:@protocol(EXFaceDetectorManager) exception:nil];
  if (faceDetector) {
    __weak EXCamera *weakSelf = self;
    [faceDetector setOnFacesDetected:^(NSArray<NSDictionary *> *faces) {
      __strong EXCamera *strongSelf = weakSelf;
      if (strongSelf) {
        if (strongSelf.onFacesDetected) {
          strongSelf.onFacesDetected(@{
                                       @"type": @"face",
                                       @"faces": faces
                                       });
        }
      }
    }];
    [faceDetector setSessionQueue:_sessionQueue];
  }
  return faceDetector;
}

@end

