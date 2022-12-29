//
//  SOSPicker.m
//  SyncOnSet
//
//  Created by Christopher Sullivan on 10/25/13.
//
//

#import "SOSPicker.h"


#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>

#define CDV_PHOTO_PREFIX @"cdv_photo_"

typedef enum : NSUInteger {
    FILE_URI = 0,
    BASE64_STRING = 1
} SOSPickerOutputType;

@interface SOSPicker () <PHPickerViewControllerDelegate>
@end

@implementation SOSPicker{
    UIScrollView *scrollView;
    NSMutableArray <UIImageView*>* imageViews;
    UIButton *selectButton;
}

@synthesize callbackId;

- (void) hasReadPermission:(CDVInvokedUrlCommand *)command {
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:[PHPhotoLibrary authorizationStatus] == PHAuthorizationStatusAuthorized];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) requestReadPermission:(CDVInvokedUrlCommand *)command {
    // [PHPhotoLibrary requestAuthorization:]
    // this method works only when it is a first time, see
    // https://developer.apple.com/library/ios/documentation/Photos/Reference/PHPhotoLibrary_Class/

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusAuthorized) {
        NSLog(@"Access has been granted.");
    } else if (status == PHAuthorizationStatusDenied) {
        NSLog(@"Access has been denied. Change your setting > this app > Photo enable");
    } else if (status == PHAuthorizationStatusNotDetermined) {
        // Access has not been determined. requestAuthorization: is available
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {}];
    } else if (status == PHAuthorizationStatusRestricted) {
        NSLog(@"Access has been restricted. Change your setting > Privacy > Photo enable");
    }

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getPictures:(CDVInvokedUrlCommand *)command {
    NSDictionary *options = [command.arguments objectAtIndex: 0];

    self.outputType = [[options objectForKey:@"outputType"] integerValue];
    BOOL allow_video = [[options objectForKey:@"allow_video" ] boolValue ];
    NSInteger maximumImagesCount = [[options objectForKey:@"maximumImagesCount"] integerValue];
    NSString * title = [options objectForKey:@"title"];
    NSString * message = [options objectForKey:@"message"];
    BOOL disable_popover = [[options objectForKey:@"disable_popover" ] boolValue];
    if (message == (id)[NSNull null]) {
      message = nil;
    }
    self.width = [[options objectForKey:@"width"] integerValue];
    self.height = [[options objectForKey:@"height"] integerValue];
    self.quality = [[options objectForKey:@"quality"] integerValue];

    self.callbackId = command.callbackId;
    [self launchGMImagePicker:allow_video title:title message:message disable_popover:disable_popover maximumImagesCount:maximumImagesCount];
}

- (void)launchGMImagePicker:(bool)allow_video title:(NSString *)title message:(NSString *)message disable_popover:(BOOL)disable_popover maximumImagesCount:(NSInteger)maximumImagesCount
{
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.selectionLimit = maximumImagesCount;
    if (@available(iOS 15, *)) {
        config.selection = PHPickerConfigurationSelectionOrdered;
    }
    config.filter = [PHPickerFilter imagesFilter];

    PHPickerViewController *pickerViewController = [[PHPickerViewController alloc] initWithConfiguration:config];
    pickerViewController.delegate = self;

    pickerViewController.modalPresentationStyle = UIModalPresentationPopover;

    [self.viewController presentViewController:pickerViewController animated:YES completion:nil];
}

- (UIImage*)imageByScalingNotCroppingForSize:(UIImage*)anImage toSize:(CGSize)frameSize
{
    UIImage* sourceImage = anImage;
    UIImage* newImage = nil;
    CGSize imageSize = sourceImage.size;
    CGFloat width = imageSize.width;
    CGFloat height = imageSize.height;
    CGFloat targetWidth = frameSize.width;
    CGFloat targetHeight = frameSize.height;
    CGFloat scaleFactor = 0.0;
    CGSize scaledSize = frameSize;

    if (CGSizeEqualToSize(imageSize, frameSize) == NO) {
        CGFloat widthFactor = targetWidth / width;
        CGFloat heightFactor = targetHeight / height;

        // opposite comparison to imageByScalingAndCroppingForSize in order to contain the image within the given bounds
        if (widthFactor == 0.0) {
            scaleFactor = heightFactor;
        } else if (heightFactor == 0.0) {
            scaleFactor = widthFactor;
        } else if (widthFactor > heightFactor) {
            scaleFactor = heightFactor; // scale to fit height
        } else {
            scaleFactor = widthFactor; // scale to fit width
        }
        scaledSize = CGSizeMake(floor(width * scaleFactor), floor(height * scaleFactor));
    }

    UIGraphicsBeginImageContext(scaledSize); // this will resize

    [sourceImage drawInRect:CGRectMake(0, 0, scaledSize.width, scaledSize.height)];

    newImage = UIGraphicsGetImageFromCurrentImageContext();
    if (newImage == nil) {
        NSLog(@"could not scale image");
    }

    // pop the context to get back to the default
    UIGraphicsEndImageContext();
    return newImage;
}


#pragma mark - UIImagePickerControllerDelegate

-(void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results{
    NSLog(@"-picker:%@ didFinishPicking:%@", picker, results);

    [picker dismissViewControllerAnimated:YES completion:nil];

    NSMutableArray * result_all = [[NSMutableArray alloc] init];
    CGSize targetSize = CGSizeMake(self.width, self.height);
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];

    //NSError* err = nil;
    __block CDVPluginResult* cdvResult = nil;

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"Processing images for upload..."
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIActivityIndicatorView *loadingIndicator = [[UIActivityIndicatorView alloc] initWithFrame: CGRectMake(10, 5, 50, 50)];
    loadingIndicator.activityIndicatorViewStyle = UIActivityIndicatorViewStyleMedium;
    alert.view.tintColor = UIColor.blackColor;

    loadingIndicator.hidesWhenStopped = true;
    [loadingIndicator startAnimating];

    [alert.view addSubview:loadingIndicator];

    [self.viewController presentViewController:alert animated:YES completion:nil];

    dispatch_group_t dispatchGroup = dispatch_group_create();

    __block int i = 1;
    int orderIterative = 1;

    for (PHPickerResult *result in results) {
        int order = orderIterative++;

        dispatch_group_async(dispatchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            dispatch_group_enter(dispatchGroup);

            [result.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading>  _Nullable object, NSError * _Nullable error) {
                __block NSError* writeErr = nil;

                NSString* filePath;

                do {
                    filePath = [NSString stringWithFormat:@"%@/%@%03d.%@", docsPath, CDV_PHOTO_PREFIX, i++, @"jpg"];
                } while ([fileMgr fileExistsAtPath:filePath]);

                if ([object isKindOfClass:[UIImage class]]) {

                    NSData* data = nil;

                    if (self.width == 0 && self.height == 0) {
                        // no scaling required
                        if (self.outputType == BASE64_STRING){
                            NSMutableDictionary* objectToInsert = [[NSMutableDictionary alloc] init];
                            [objectToInsert setValue:[NSNumber numberWithInt:order] forKey:@"order"];
                            [objectToInsert setValue:[UIImageJPEGRepresentation(object, self.quality/100.0f) base64EncodedStringWithOptions:0] forKey:@"data"];

                            [result_all addObject:objectToInsert];
                        } else {
                            // resample first
                            UIImage* image = [UIImage imageNamed:object];
                            data = UIImageJPEGRepresentation(image, self.quality/100.0f);
                            if (![data writeToFile:filePath options:NSAtomicWrite error:&writeErr]) {
                                cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[writeErr localizedDescription]];
                            } else {
                                NSMutableDictionary* objectToInsert = [[NSMutableDictionary alloc] init];
                                [objectToInsert setValue:[NSNumber numberWithInt:order] forKey:@"order"];
                                [objectToInsert setValue:[[NSURL fileURLWithPath:filePath] absoluteString] forKey:@"data"];

                                [result_all addObject:objectToInsert];
                            }
                        }
                    } else {
                        // scale
                        UIImage* scaledImage = [self imageByScalingNotCroppingForSize:object toSize:targetSize];
                        data = UIImageJPEGRepresentation(scaledImage, self.quality/100.0f);

                        if (![data writeToFile:filePath options:NSAtomicWrite error:&writeErr]) {
                            cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[writeErr localizedDescription]];
                        } else {
                            if(self.outputType == BASE64_STRING){
                                NSMutableDictionary* objectToInsert = [[NSMutableDictionary alloc] init];
                                [objectToInsert setValue:[NSNumber numberWithInt:order] forKey:@"order"];
                                [objectToInsert setValue:[data base64EncodedStringWithOptions:0] forKey:@"data"];

                                [result_all addObject:objectToInsert];
                            } else {

                                NSMutableDictionary* objectToInsert = [[NSMutableDictionary alloc] init];
                                [objectToInsert setValue:[NSNumber numberWithInt:order] forKey:@"order"];
                                [objectToInsert setValue:[[NSURL fileURLWithPath:filePath] absoluteString] forKey:@"data"];

                                [result_all addObject:objectToInsert];
                            }
                        }
                    }
                    dispatch_group_leave(dispatchGroup);
                }
            }];
        });
    }

    dispatch_group_notify(dispatchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSLog(@"finally!");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (cdvResult == nil) {
                NSMutableArray * result_return = [[NSMutableArray alloc] init];

                NSArray *sortedArray = [result_all sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [[a valueForKey:@"order"] compare:[b valueForKey:@"order"]];
                }];

                for (NSDictionary* object in sortedArray) {
                    [result_return addObject:[object valueForKey:@"data"]];
                }

                cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:result_return];
            }

            [self.viewController dismissViewControllerAnimated:YES completion:nil];
            [self.commandDelegate sendPluginResult:cdvResult callbackId:self.callbackId];
        });
    });
}

@end
