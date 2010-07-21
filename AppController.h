// ©2009 Andreas Beier & c't - Magazin für Computertechnik (adb@ctmagazin.de)

#import <Cocoa/Cocoa.h>
#include <CoreServices/CoreServices.h>

@interface AppController : NSObject {
	IBOutlet NSWindow		*prefsWindow;
	IBOutlet NSTableView	*tableView;
	IBOutlet NSButton		*addFolderButton;
	IBOutlet NSButton		*deleteFolderButton;
	
	NSMutableArray			*foldersToBackup;
	
	FSEventStreamRef		fsStream;
    FSEventStreamContext	*fsContext;
	BOOL					isRunning;
	
@public
	IBOutlet NSPathControl	*backupPathControl;
	IBOutlet NSTextField	*statusField;
	IBOutlet NSMenu			*statusMenu;
	NSStatusItem			*menuItem;
	NSTimer					*blinkenTimer;
	BOOL					errorWasSeen;
}

- (void)deleteAlertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)openPanelDidEnd:(NSOpenPanel *)panel returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void)backupPathControlDoubleClick:(id)sender;
- (void)chooseFolderAtDirectory:(NSString *)startPath contextInfo:(void *)contextInfo;

- (IBAction)changeBackup:(id)sender;
- (IBAction)addFolder:(id)sender;
- (IBAction)deleteFolder:(id)sender;
- (IBAction)handleLoginItemStatus:(id)sender;

- (void)setBlinkenTimer:(NSTimer *)newTimer;

@end
