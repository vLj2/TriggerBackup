// ©2009 Andreas Beier & c't - Magazin für Computertechnik (adb@ctmagazin.de)
// Growl support added by h0sch1 (hoschi@anukis.de)

#include <sys/stat.h>
#import "AppController.h"
#import <CommonCrypto/CommonDigest.h>


// static function to send Growl messages
static void sendGrowlMessage(NSString *growlMessage, BOOL isSticky) 
{
	[GrowlApplicationBridge notifyWithTitle:@"TriggerBackup"
								description:growlMessage
						   notificationName:@"Information"
								   iconData:nil
								   priority:1
								   isSticky:isSticky
							   clickContext:nil]; 	
}


static BOOL filesAreIdentical(NSString *file1, NSString *file2)
{
	BOOL isDir;
	NSFileManager *fm = [NSFileManager defaultManager];
	
	if ([fm fileExistsAtPath:file1 isDirectory:&isDir] && isDir) // Datei1 ist Verzeichnis, keine MD5-Prüfsumme möglich
		return YES;
	
	NSData *data = [[NSData alloc] initWithContentsOfFile:file1];
	if (data) {
		unsigned char md5Result[CC_MD5_DIGEST_LENGTH];
		CC_MD5([data bytes], [data length], md5Result);
		[data release];

		NSData *backupData = [[NSData alloc] initWithContentsOfFile:file2];
		if (backupData) {
			unsigned char md5BackupResult[CC_MD5_DIGEST_LENGTH];
			CC_MD5([backupData bytes], [backupData length], md5BackupResult);
			[backupData release];

			for (NSInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
				if (md5Result[i] != md5BackupResult[i]) {
					NSLog(@"TriggerBackup: MD5 checksum error: %@ -> %@", file1, file2);
					sendGrowlMessage([NSString stringWithFormat:NSLocalizedString(@"GrowlChecksumError", nil), file1], NO);
					return NO;
				}
			}
			
			return YES;
			
//			NSMutableString *md5String = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
//			NSMutableString *md5BackupString = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
//
//			for (NSInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
//				[md5String appendFormat:@"%02x", md5Result[i]];
//				[md5BackupString appendFormat:@"%02x", md5BackupResult[i]];
//			}
//			
//			return [md5String isEqualToString:md5BackupString];
		} else {
			NSLog(@"TriggerBackup: MD5 checksum error: source file %@ not readable", file1);
			sendGrowlMessage([NSString stringWithFormat:NSLocalizedString(@"GrowlChecksumError", nil), file1], NO);
		}
	} else {
		NSLog(@"TriggerBackup: MD5 checksum error:  backup file %@ not readable", file2);
		sendGrowlMessage([NSString stringWithFormat:NSLocalizedString(@"GrowlChecksumError", nil), file2], NO);
	}
	
	return NO;
}


static NSString *pathWithVersionNumber(NSString *path, NSUInteger version)
{
	NSString *extension = [path pathExtension]; // ergibt "txt" bei "~/Test.txt"
	NSString *pathNoExtension = [path stringByDeletingPathExtension]; // ergibt "Test" bei "~/Test.txt"

	if ([extension length] == 0) {
		return [NSString stringWithFormat:@"%@_%u", pathNoExtension, version]; // etwa "~/Test_0"
	} else {
		return [NSString stringWithFormat:@"%@_%u.%@", pathNoExtension, version, extension]; // "~/Test_0.txt"
	}
}


static void fsCallback(ConstFSEventStreamRef streamRef, void *clientCallBackInfo, size_t numEvents, void *eventPaths, const FSEventStreamEventFlags eventFlags[], const FSEventStreamEventId eventIds[]) 
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	AppController *appController = (AppController *)clientCallBackInfo;
	
	NSString *backupDir = [[appController->backupPathControl URL] relativePath];
	NSFileManager *fm = [NSFileManager defaultManager];
	char **paths = eventPaths;
	NSDictionary *strAttributes = [[[NSDictionary alloc] initWithObjectsAndKeys:[NSFont fontWithName:@"Lucida Grande" size:10], NSFontAttributeName, nil] autorelease];
	NSMenuItem *errorItem = [appController->statusMenu itemWithTag:174];

	BOOL isDir;
	if (![fm fileExistsAtPath:backupDir isDirectory:&isDir] || !isDir) { // Backup-Verzeichnis fehlt oder ist kein Verzeichnis							
		[appController->menuItem setImage:[NSImage imageNamed:@"MenuIconNotRunning"]];
		[appController->statusField setStringValue:NSLocalizedString(@"FolderWatchBackupDirMissing", nil)];
		NSAttributedString *attrString = [[[NSAttributedString alloc] initWithString:NSLocalizedString(@"ErrorBackupFolderMissingError", nil) attributes: strAttributes] autorelease];
		sendGrowlMessage(NSLocalizedString(@"GrowlBackupFolderMissingError", nil), YES);
		[errorItem setAttributedTitle:attrString];
		appController->errorWasSeen = NO;
		return;
	}

	FSRef fileRef;
	LSItemInfoRecord infoRecord;
	OSStatus result;

    for (NSUInteger i = 0; i < numEvents; i++) { // Anzahl der gemeldeten, geänderten Verzeichnisse
		NSString *workDir = [NSString stringWithUTF8String:paths[i]];
		result = FSPathMakeRef((UInt8 *)paths[i], &fileRef, (Boolean *)NULL);
		result = LSCopyItemInfoForRef(&fileRef, kLSRequestAllFlags, &infoRecord);
		UInt32 isPackage = infoRecord.flags & kLSItemInfoIsPackage;
		
		if (isPackage) { // Package -> komplett sichern, nicht nur den geänderten Inhalt
			// Überprüfung auf Inhaltsänderungen überflüssig, sonst wäre das Package nicht als geändert hier aufgeführt
			NSString *filePath = workDir;
			NSString *backupFilePath = [backupDir stringByAppendingPathComponent:filePath];
			NSDictionary *fileAttributes = [fm attributesOfItemAtPath:filePath error:NULL];
			if (![fm fileExistsAtPath:backupFilePath]) { // Package existiert noch nicht im Backup
				// sichern
				[fm createDirectoryAtPath:[backupFilePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
				[fm copyItemAtPath:filePath toPath:backupFilePath error:NULL];
				[fm setAttributes:fileAttributes ofItemAtPath:backupFilePath error:NULL]; // für blöde SMB-Server
				
			} else { // Package existiert bereits im Backup
				// zuerst Versionsnummer ermitteln
				NSInteger vers;
				for (vers = 0; vers < 11; vers++) {
					if ((vers > 9) || (![fm fileExistsAtPath:pathWithVersionNumber(backupFilePath, vers)]))
						break;
				}

				if (vers > 9) { // zu viele Versionen, älteste (*_0) wegwerfen, Rest schieben: _x -> _(x-1)
					[fm removeItemAtPath:pathWithVersionNumber(backupFilePath, 0) error:NULL];
					for (vers = 1; vers < 10; vers++) {
						if ([fm fileExistsAtPath:pathWithVersionNumber(backupFilePath, vers)])
							[fm moveItemAtPath:pathWithVersionNumber(backupFilePath, vers) toPath:pathWithVersionNumber(backupFilePath, vers-1) error:NULL];
					}
					vers = 9;
				}
							
				// bisher aktuelle Version umbenennen
				[fm moveItemAtPath:backupFilePath toPath:pathWithVersionNumber(backupFilePath, vers) error:NULL];
				// zu sichernde Datei kopieren
				[fm copyItemAtPath:filePath toPath:backupFilePath error:NULL];
				[fm setAttributes:fileAttributes ofItemAtPath:backupFilePath error:NULL];
			}
		} else { // normales Verzeichnis -> einzelne Dateien überprüfen
			NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:workDir];
			BOOL firstChecksumError = YES;
			NSString *file;
			
			while (file = [dirEnum nextObject]) { // alle Einträge eines gemeldeten Ordners
				NSString *filePath = [workDir stringByAppendingPathComponent:file];
				NSString *backupFilePath = [backupDir stringByAppendingPathComponent:filePath];
				NSDictionary *fileAttributes = [fm attributesOfItemAtPath:filePath error:NULL];

				struct stat fileAttribs;
				if(stat([filePath UTF8String], &fileAttribs) == 0) { // filePath ist gültig
					if (fileAttribs.st_mode & S_IFREG) { // Datei -> potentieller Backup-Kandidat
						if ((fileAttribs.st_atimespec.tv_sec - 3) <= fileAttribs.st_mtimespec.tv_sec) { // letzter Zugriff war schreibend -> Backup
							// - 3, weil Spotlight nach dem Schreiben einer Datei diese sofort indiziert und deshalb atime aktualisiert wird
							if (![fm fileExistsAtPath:backupFilePath]) { // Package existiert noch nicht im Backup
								// sichern
								[fm createDirectoryAtPath:[backupFilePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
								[fm copyItemAtPath:filePath toPath:backupFilePath error:NULL];
								[fm setAttributes:fileAttributes ofItemAtPath:backupFilePath error:NULL]; // für blöde SMB-Server
								
								if (!filesAreIdentical(filePath, backupFilePath) && firstChecksumError) {
									NSAttributedString *attrString = [[[NSAttributedString alloc] initWithString:NSLocalizedString(@"ErrorChecksumError", nil) attributes: strAttributes] autorelease];
									[errorItem setAttributedTitle:attrString];
									[appController setBlinkenTimer:[NSTimer scheduledTimerWithTimeInterval:1.5 target:appController selector:@selector(timerFireMethod:) userInfo:nil repeats:YES]];
									firstChecksumError = NO;
									appController->errorWasSeen = NO;
								}
							} else { // Datei existiert im Backup -> Versionierung
								// zuerst Versionsnummer ermitteln
								NSInteger vers;
								for (vers = 0; vers < 11; vers++) {
									if ((vers > 9) || (![fm fileExistsAtPath:pathWithVersionNumber(backupFilePath, vers)]))
										break;
								}							
								
								if (vers > 9) { // zu viele Versionen, älteste (_0) wegwerfen, Rest schieben: _x -> _(x-1)
									[fm removeItemAtPath:pathWithVersionNumber(backupFilePath, 0) error:NULL];
									for (vers = 1; vers < 10; vers++) {
										if ([fm fileExistsAtPath:pathWithVersionNumber(backupFilePath, vers)])
											[fm moveItemAtPath:pathWithVersionNumber(backupFilePath, vers) toPath:pathWithVersionNumber(backupFilePath, vers-1) error:NULL];
									}
									vers = 9;
								}
								
								// bisher aktuelle Version umbenennen
								[fm moveItemAtPath:backupFilePath toPath:pathWithVersionNumber(backupFilePath, vers) error:NULL];
								// zu sichernde Datei kopieren
								[fm copyItemAtPath:filePath toPath:backupFilePath error:NULL];
								[fm setAttributes:fileAttributes ofItemAtPath:backupFilePath error:NULL]; // für blöde SMB-Server
								
								if (!filesAreIdentical(filePath, backupFilePath) && firstChecksumError) {
									NSAttributedString *attrString = [[[NSAttributedString alloc] initWithString:NSLocalizedString(@"ErrorChecksumError", nil) attributes: strAttributes] autorelease];
									[errorItem setAttributedTitle:attrString];
									[appController setBlinkenTimer:[NSTimer scheduledTimerWithTimeInterval:1.5 target:appController selector:@selector(timerFireMethod:) userInfo:nil repeats:YES]];
									firstChecksumError = NO;
									appController->errorWasSeen = NO;
								}
							} // if (![fm fileExistsAtPath:backupFilePath])
						} // if (fileAttribs.st_atimespec.tv_sec <= fileAttribs.st_mtimespec.tv_sec)
					} // if (fileAttribs.st_mode & S_IFREG) 
				} // if(stat([filePath UTF8String], &fileAttribs) == 0)
			} // End of while (file = [dirEnum nextObject]) 
		} // End of else/no package
	} // End of for (NSUInteger i = 0; i < numEvents; i++)	
	
	[pool drain];
}


@implementation AppController

- (void)timerFireMethod:(NSTimer*)theTimer
{
	static NSUInteger counter = 0;
	
	if ((counter % 2) == 0)
		[menuItem setImage:[NSImage imageNamed:@"MenuIconNotRunning"]];
	else
		[menuItem setImage:[NSImage imageNamed:@"MenuIcon"]];
	
	counter++;
}


- (void)setBlinkenTimer:(NSTimer *)newTimer
{
	if (blinkenTimer)
		[blinkenTimer invalidate];
	
	blinkenTimer = newTimer;
}


- (void)addAppToLoginItems
{
	NSURL *appURL = [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];
	LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);

	// TriggerBackup am Ende der Liste einfügen
	LSSharedFileListItemRef item = LSSharedFileListInsertItemURL(loginItems, kLSSharedFileListItemLast, NULL, NULL, (CFURLRef)appURL, NULL, NULL);		
	if (item)
		CFRelease(item);

	CFRelease(loginItems);
}


- (void)deleteAppFromLoginItems
{
	UInt32 seedValue;
	NSString *appPath = [[NSBundle mainBundle] bundlePath];
	NSURL *thePath;
	LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
	
	NSArray  *loginItemsArray = (NSArray *)LSSharedFileListCopySnapshot(loginItems, &seedValue);
	for (id item in loginItemsArray) {		
		LSSharedFileListItemRef itemRef = (LSSharedFileListItemRef)item;
		if (LSSharedFileListItemResolve(itemRef, 0, (CFURLRef*)&thePath, NULL) == noErr) {
			if ([[thePath relativePath] hasPrefix:appPath])
				LSSharedFileListItemRemove(loginItems, itemRef); // Eintrag von TriggerBackup löschen
		}
	}
	
	[loginItemsArray release];
	
	CFRelease(loginItems);
}


- (BOOL)appIsInLoginItems
{
	UInt32 seedValue;
	BOOL appFound = NO;
	NSURL *path;
	NSString *appPath = [[NSBundle mainBundle] bundlePath];
	LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
	
	NSArray *loginItemsArray = (NSArray *)LSSharedFileListCopySnapshot(loginItems, &seedValue);
	for (id item in loginItemsArray) {		
		LSSharedFileListItemRef itemRef = (LSSharedFileListItemRef)item;
		if (LSSharedFileListItemResolve(itemRef, 0, (CFURLRef *)&path, NULL) == noErr) {
			if ([[path relativePath] hasPrefix:appPath]) {
				appFound = YES;
				break;
			}
		}
	}
	
	[loginItemsArray release];
	CFRelease(loginItems);
	
	return appFound;
}


- (IBAction)handleLoginItemStatus:(id)sender
{
	NSMenuItem *loginMenuItem = [statusMenu itemWithTag:215];
	if ([self appIsInLoginItems]) {
		[self deleteAppFromLoginItems];
		[loginMenuItem setState:NSOffState];		
	} else {
		[self addAppToLoginItems];
		[loginMenuItem setState:NSOnState];
	}
}


- (void)saveSettings
{
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	[userDefaults setObject:foldersToBackup forKey:@"foldersToBackup"];
	[userDefaults setObject:[[backupPathControl URL] relativePath] forKey:@"backupFolder"];
	[userDefaults synchronize];
}


- (void)updateFSStream
{
	// aktuellen fsStream anhalten und wegwerfen 
	if (fsStream) {
		if (isRunning)
			FSEventStreamStop(fsStream);
		
		FSEventStreamInvalidate(fsStream);
		FSEventStreamRelease(fsStream);
		fsStream = nil;
	}
	
	isRunning = NO;
	
	BOOL isDir = NO;
	NSString *backupDir = [[backupPathControl URL] relativePath];
	if (![[NSFileManager defaultManager] fileExistsAtPath:backupDir isDirectory:&isDir] || !isDir) // Backup-Verzeichnis fehlt oder ist kein Verzeichnis							
		sendGrowlMessage(NSLocalizedString(@"GrowlBackupFolderMissingError", nil), YES);
		
	if ([foldersToBackup count] > 0) { // Daten vorhanden, neuen fsStream anlegen
		// Daten vorbereiten
		NSMutableArray *pathsToWatch = [NSMutableArray arrayWithCapacity:[foldersToBackup count]];
		NSUInteger i;
		for (i = 0; i < [foldersToBackup count]; i++) {
			NSString *tmp = [[NSURL URLWithString:[foldersToBackup objectAtIndex:i]] relativePath];
			[pathsToWatch addObject:tmp];
		}
		
		fsStream = FSEventStreamCreate(NULL,
									   &fsCallback,
									   fsContext,
									   (CFArrayRef)pathsToWatch,
									   kFSEventStreamEventIdSinceNow,
									   1.0,
									   kFSEventStreamCreateFlagNone);
		
		FSEventStreamScheduleWithRunLoop(fsStream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);    
		
		isRunning = FSEventStreamStart(fsStream); // Überwachung starten
		if (!isRunning) { // FEHLER
			NSAlert *errorAlert = [NSAlert alertWithMessageText:NSLocalizedString(@"ErrorStartTitle", nil)
												  defaultButton:@"Oh" 
												alternateButton:nil 
													otherButton:nil 
									  informativeTextWithFormat:NSLocalizedString(@"ErrorStartMessage", nil), nil];
			
			[errorAlert beginSheetModalForWindow:prefsWindow 
								   modalDelegate:self 
								  didEndSelector:nil 
									 contextInfo:nil];
			
			[statusField setStringValue:NSLocalizedString(@"FolderWatchNotRunning", nil)];
			[menuItem setImage:[NSImage imageNamed:@"MenuIconNotRunning"]];
		} else {
			NSDate *now = [NSDate date];
			[statusField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"FolderWatchUpdated", nil), [now descriptionWithLocale:[NSLocale currentLocale]]]];
			[menuItem setImage:[NSImage imageNamed:@"MenuIcon"]];
		}
	} else {
		[statusField setStringValue:NSLocalizedString(@"FolderWatchNothingToWatch", nil)];
		[menuItem setImage:[NSImage imageNamed:@"MenuIcon"]];
	}
}


- (void)deleteAlertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	if (returnCode != NSOKButton) { // ist beim Löschen der Nein-Button
		NSIndexSet *selectedFolders = [tableView selectedRowIndexes];
		
		NSUInteger currentIndex = [selectedFolders lastIndex];
		while (currentIndex != NSNotFound) {
			[foldersToBackup removeObjectAtIndex:currentIndex];
			currentIndex = [selectedFolders indexLessThanIndex:currentIndex];
		}
		
		[tableView reloadData];
		[tableView deselectRow:[tableView selectedRow]];

		[self updateFSStream];
		[self saveSettings];
	}
}


- (void)openPanelDidEnd:(NSOpenPanel *)panel returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	if (returnCode == NSOKButton) {
		NSArray *files = [panel filenames];
		NSString *path = [files objectAtIndex:0];
		
		if ((NSInteger)contextInfo == 215) { // weiterer Ordner soll überwacht werden
			FSRef fileRef;
			LSItemInfoRecord infoRecord;
			OSStatus result = FSPathMakeRef((UInt8 *)[path UTF8String], &fileRef, (Boolean *)NULL);
			result = LSCopyItemInfoForRef(&fileRef, kLSRequestAllFlags, &infoRecord);
			UInt32 isVolume = infoRecord.flags & kLSItemInfoIsVolume;
			
			if (isVolume) { // komplette Volumes werden nicht überwacht
				[panel orderOut:self];
				
				NSAlert *errorAlert = [NSAlert alertWithMessageText:NSLocalizedString(@"ErrorAddFolderTitle", nil)
													  defaultButton:@"Oh" 
													alternateButton:nil 
														otherButton:nil 
										  informativeTextWithFormat:NSLocalizedString(@"ErrorAddFolderMessage", nil), nil];
				
				[errorAlert beginSheetModalForWindow:prefsWindow 
									   modalDelegate:self 
									  didEndSelector:nil 
										 contextInfo:nil];
			} else { // "normaler" Ordner
				NSUInteger i;
				BOOL alreadyWatched = NO;
				for (i = 0; i < [foldersToBackup count]; i++) { // wird der Ordner schon überwacht
					NSString *tmp = [[NSURL URLWithString:[foldersToBackup objectAtIndex:i]] relativePath];
					if ([path isEqualToString:tmp]) {
						alreadyWatched = YES;
						break;
					}
				}
				
				if (!alreadyWatched) {
					[foldersToBackup addObject:[[NSString stringWithFormat:@"file://%@", path] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
					[self performSelectorInBackground:@selector(doFullBackupForFolder:) withObject:path]; // initiales Backup für neuen Ordner anstoßen
					[self updateFSStream];
				}
				
				[tableView reloadData];
				[tableView deselectRow:[tableView selectedRow]];
			}
			
		} else { // Backup-Verzeichnis hat sich geändert
			[backupPathControl setURL:[NSURL URLWithString:[[NSString stringWithFormat:@"file://%@", path] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
			NSDate *now = [NSDate date];
			[statusField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"FolderWatchUpdated", nil), [now descriptionWithLocale:[NSLocale currentLocale]]]];
			[self performSelectorInBackground:@selector(doFullBackupForFolder:) withObject:nil]; // initiales Backup für alle zu überwachenden Ordner anstoßen
		}
		
		[self saveSettings];
	}
}


- (void)chooseFolderAtDirectory:(NSString *)startPath contextInfo:(void *)contextInfo
{
	NSOpenPanel* openDlg = [NSOpenPanel openPanel];
	[openDlg setCanChooseFiles:NO];
	[openDlg setCanChooseDirectories:YES];
	[openDlg setCanCreateDirectories:YES];
	[openDlg setAllowsMultipleSelection:NO];
	
	[openDlg beginSheetForDirectory:startPath 
							   file:nil 
							  types:nil 
					 modalForWindow:prefsWindow 
					  modalDelegate:self 
					 didEndSelector:@selector(openPanelDidEnd:returnCode:contextInfo:) 
						contextInfo:contextInfo];
}


- (void)backupPathControlDoubleClick:(id)sender 
{
	NSPathComponentCell *clickedPathComponent = [(NSPathControl *)sender clickedPathComponentCell];
	
	[self chooseFolderAtDirectory:[[clickedPathComponent URL] relativePath] contextInfo:nil];
}


- (IBAction)changeBackup:(id)sender
{
	[self chooseFolderAtDirectory:[[backupPathControl URL] relativePath] contextInfo:nil]; // contextInfo ≠ 0 heißt "Backup-Verzeichnis auswählen"
}


- (IBAction)addFolder:(id)sender
{
	[self chooseFolderAtDirectory:[[backupPathControl URL] relativePath] contextInfo:(void *)215]; // contextInfo ≠ 0 heißt "neuer Ordner überwachen"
}


- (IBAction)deleteFolder:(id)sender
{
	NSAlert *deleteAlert = [NSAlert alertWithMessageText:NSLocalizedString(@"DeleteTitle", nil)
										   defaultButton:NSLocalizedString(@"No", nil) 
										 alternateButton:nil 
											 otherButton:NSLocalizedString(@"Yes", nil)
							   informativeTextWithFormat:NSLocalizedString(@"DeleteMessage", nil), nil];

	[deleteAlert beginSheetModalForWindow:prefsWindow 
							modalDelegate:self 
						   didEndSelector:@selector(deleteAlertDidEnd:returnCode:contextInfo:) 
							  contextInfo:nil];
}


- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
	[deleteFolderButton setEnabled:([tableView selectedRow] >= 0)];
}


- (NSCell *)tableView:(NSTableView *)tableView dataCellForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	NSPathCell *pathCell = [[[NSPathCell alloc] init] autorelease];
	[pathCell setBackgroundColor:[NSColor clearColor]];
	[pathCell setPathStyle:NSPathStyleStandard];
	[pathCell setFont:[NSFont systemFontOfSize:10.0]];
	
	return pathCell;
}


- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return [foldersToBackup count];;
}


- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	return [NSURL URLWithString:[foldersToBackup objectAtIndex:rowIndex]];
}


- (NSString *)tableView:(NSTableView *)aTableView toolTipForCell:(NSCell *)aCell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *path = [[NSURL URLWithString:[foldersToBackup objectAtIndex:row]] relativePath];
	NSArray *entries = [fm contentsOfDirectoryAtPath:path error:NULL];

	NSUInteger count = [entries count];
	if (count == 1) 
		return [NSString stringWithFormat:NSLocalizedString(@"FolderOneObject", nil), path];
	else if (count == 0) 
		return [NSString stringWithFormat:NSLocalizedString(@"FolderEmpty", nil), path];
	else
		return [NSString stringWithFormat:NSLocalizedString(@"FolderLotsOfObjects", nil), path, [entries count]];
}


- (void)menuNeedsUpdate:(NSMenu *)menu
{
	NSMenuItem *loginMenuItem = [statusMenu itemWithTag:215];
	if ([self appIsInLoginItems])
		[loginMenuItem setState:NSOnState];
	else
		[loginMenuItem setState:NSOffState];
	
	NSDictionary *strAttributes = [[[NSDictionary alloc] initWithObjectsAndKeys:[NSFont fontWithName:@"Lucida Grande" size:10], NSFontAttributeName, nil] autorelease];	
	
	NSString *backupDir = [[backupPathControl URL] relativePath];
	NSFileManager *fm = [NSFileManager defaultManager];
	
	BOOL isDir;
	if (![fm fileExistsAtPath:backupDir isDirectory:&isDir] || !isDir) { // Backup-Verzeichnis fehlt oder ist kein Verzeichnis							
		[menuItem setImage:[NSImage imageNamed:@"MenuIconNotRunning"]];
		[statusField setStringValue:NSLocalizedString(@"FolderWatchBackupDirMissing", nil)];
		NSAttributedString *attrString = [[[NSAttributedString alloc] initWithString:NSLocalizedString(@"ErrorBackupFolderMissingError", nil) attributes: strAttributes] autorelease];
		[[statusMenu itemWithTag:174] setAttributedTitle:attrString];
		errorWasSeen = NO;
		return;
	} else {
		[menuItem setImage:[NSImage imageNamed:@"MenuIcon"]];
	}
	
	if (blinkenTimer && [blinkenTimer isValid]) {
		[blinkenTimer invalidate];
		blinkenTimer = nil;
		errorWasSeen = YES;
	} else {
		if (errorWasSeen) {
			[menuItem setImage:[NSImage imageNamed:@"MenuIcon"]];
			NSDate *now = [NSDate date];
			[statusField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"FolderWatchUpdated", nil), [now descriptionWithLocale:[NSLocale currentLocale]]]];
			NSAttributedString *attrString = [[[NSAttributedString alloc] initWithString:NSLocalizedString(@"ErrorNoError", nil) attributes: strAttributes] autorelease];
			[[statusMenu itemWithTag:174] setAttributedTitle:attrString];
		} else
			errorWasSeen = YES;
	}
}


- (NSString*)versionString;
{
    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *mainString = [infoDict valueForKey:@"CFBundleShortVersionString"];
    NSString *subString = [infoDict valueForKey:@"CFBundleVersion"];
	return [NSString stringWithFormat:@"Version %@ (%@)", mainString, subString];
}


// Growl registration
- (NSDictionary*) registrationDictionaryForGrowl 
{ 
	NSArray* defaults = [NSArray arrayWithObjects:@"Information", nil]; 
	NSArray* all = [NSArray arrayWithObjects:@"Information", nil]; 
	NSDictionary* growlRegDict = [NSDictionary dictionaryWithObjectsAndKeys:defaults, GROWL_NOTIFICATIONS_DEFAULT, all, GROWL_NOTIFICATIONS_ALL, nil]; 
	return growlRegDict; 
}

- (void)awakeFromNib 
{
	blinkenTimer = nil;
	
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	NSString *tmp = [NSString stringWithFormat:@"file://%@", [userDefaults objectForKey:@"backupFolder"]];
	[backupPathControl setURL:[NSURL URLWithString:[tmp stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
	[backupPathControl setDoubleAction:@selector(backupPathControlDoubleClick:)];
	
	[prefsWindow setLevel:NSTornOffMenuWindowLevel];
	
	NSArray *tmpArray = [userDefaults objectForKey:@"foldersToBackup"];
	foldersToBackup = [[NSMutableArray arrayWithArray:tmpArray] retain];	
	
	[deleteFolderButton setEnabled:([tableView selectedRow] >= 0)];
	
    fsContext = (FSEventStreamContext*)malloc(sizeof(FSEventStreamContext));
    fsContext->version = 0;
    fsContext->info = (void*)self; 
    fsContext->retain = NULL;
    fsContext->release = NULL;
    fsContext->copyDescription = NULL;
	
    isRunning = NO;
	fsStream = nil;
	
	// Growl-Aktivierung 
	[GrowlApplicationBridge setGrowlDelegate:self];
    // if ([GrowlApplicationBridge isGrowlInstalled] == NO || [GrowlApplicationBridge isGrowlRunning] == NO) {
	// } else {
	// }

    [self updateFSStream];
}


- (void)doFullBackupForFolder:(NSString *)srcFolder
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	BOOL isDir;
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dstDirPath = [[NSUserDefaults standardUserDefaults] objectForKey:@"backupFolder"];
	
	if ([fm fileExistsAtPath:dstDirPath isDirectory:&isDir] || isDir) { // backupFolder ist Verzeichnis und vorhanden							
		NSMutableArray *folderList = [NSMutableArray arrayWithCapacity:0];
		if (srcFolder) { // nur angegebenes Verzeichnis sichern
			[folderList addObject:[@"file://" stringByAppendingString:srcFolder]]; // als file-URL
		} else { // alle Verzeichnisse aus foldersToBackup sichern
			[folderList addObjectsFromArray:foldersToBackup];
		}	
			
		for (NSString *oneFolder in folderList) {
			// führendes "file://" von oneFolder abschneiden, Einträge in folderList sind file-URLs
			NSString *srcDirPath = [oneFolder substringFromIndex:7];
			
			if ([fm fileExistsAtPath:srcDirPath isDirectory:&isDir] && isDir) { // Quellverzeichnis ist Verzeichnis und vorhanden							
				[fm createDirectoryAtPath:[dstDirPath stringByAppendingPathComponent:srcDirPath] withIntermediateDirectories:YES attributes:nil error:NULL];

				NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:srcDirPath];
				NSString *fileName;
				NSString *srcFilePath, *dstFilePath;

				while ((fileName = [dirEnum nextObject])) {
					srcFilePath = [srcDirPath stringByAppendingPathComponent:fileName];
					dstFilePath = [dstDirPath stringByAppendingPathComponent:srcFilePath];
					
					if ([fm fileExistsAtPath:srcFilePath isDirectory:&isDir]) { // Quelle existiert
						if (isDir) { // Quelle ist Verzeichnis
							if (![fm fileExistsAtPath:dstFilePath]) { // Ziel existiert noch nicht
								[fm createDirectoryAtPath:dstFilePath withIntermediateDirectories:YES attributes:nil error:NULL];
							}
						} else { // Quelle ist Datei
							if (![fm fileExistsAtPath:dstFilePath]) { // Datei existiert noch nicht
								[fm copyItemAtPath:srcFilePath toPath:dstFilePath error:NULL];
							} else { // Datei existiert -> nur kopieren, wenn zu alt
								NSError *attrError;
								NSDictionary *srcFileAttributes = [fm attributesOfItemAtPath:srcFilePath error:&attrError];
								NSDictionary *dstFileAttributes = [fm attributesOfItemAtPath:dstFilePath error:&attrError];
								NSDate *srcModDate = [srcFileAttributes objectForKey:NSFileModificationDate]; 
								NSDate *dstModDate = [dstFileAttributes objectForKey:NSFileModificationDate];
								if ([srcModDate compare:dstModDate] == NSOrderedDescending) {
									[fm removeItemAtPath:dstFilePath error:NULL];
									[fm copyItemAtPath:srcFilePath toPath:dstFilePath error:NULL];
								}
								
								[fm setAttributes:srcFileAttributes ofItemAtPath:dstFilePath error:NULL]; // für blöde SMB-Server
							}
								
							filesAreIdentical(srcFilePath, dstFilePath); // Ergebnis egal, die Funktion meldet Probleme
						} // if (isDir)
					} // if Quelle existiert
				} // while ((fileName = [dirEnum nextObject]))
			} // if Quellverzeichnis ist Verzeichnis und vorhanden
		} // for (NSString *oneFolder in folderList)	
	}
			
	[pool drain];
}


-(void) applicationDidFinishLaunching:(NSNotification*)aNotification
{
	// Initialer unbedingter Backup von allen Dateien in separatem Thread ausführen
	[self performSelectorInBackground:@selector(doFullBackupForFolder:) withObject:nil];

	menuItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
	[menuItem setToolTip:NSLocalizedString(@"StatusItemToolTip", nil)];
	
	NSString *backupDir = [[NSUserDefaults standardUserDefaults] objectForKey:@"backupFolder"];
	BOOL isDir = NO;
	
	[menuItem setImage:[NSImage imageNamed:@"MenuIcon"]];

	if (![[NSFileManager defaultManager] fileExistsAtPath:backupDir isDirectory:&isDir] || !isDir) {
		[menuItem setImage:[NSImage imageNamed:@"MenuIconNotRunning"]];
	}
	
	[menuItem setHighlightMode:YES];
	[menuItem setMenu:statusMenu];
		
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	BOOL firstStartTakenCareOf = [userDefaults boolForKey:@"firstStartTakenCareOf"];
	if (!firstStartTakenCareOf) { // erster Programmstart...
		if (![self appIsInLoginItems])
			[self addAppToLoginItems];

		[userDefaults setBool:YES forKey:@"firstStartTakenCareOf"]; // ...erledigt
		[userDefaults synchronize];
		
		[prefsWindow makeKeyAndOrderFront:self];
	}
	
	NSMenuItem *loginMenuItem = [statusMenu itemWithTag:215];
	if ([self appIsInLoginItems])
		[loginMenuItem setState:NSOnState];
	else
		[loginMenuItem setState:NSOffState];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification
{
	[self saveSettings];
}


- (void)dealloc 
{
	if (isRunning)
		FSEventStreamStop(fsStream);
	
	FSEventStreamInvalidate(fsStream);
	FSEventStreamRelease(fsStream);

	free(fsContext);
	
	[menuItem release];

    [foldersToBackup release];
	[super dealloc];
}

@end
