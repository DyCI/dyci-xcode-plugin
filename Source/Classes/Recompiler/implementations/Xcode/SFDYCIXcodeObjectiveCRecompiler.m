//
// SFDYCIXcodeObjectiveCRecompiler
// SFDYCIPlugin
//
// Created by Paul Taykalo on 3/24/14.
// Copyright (c) 2014 Stanfy. All rights reserved.
//
#import "SFDYCIXcodeObjectiveCRecompiler.h"
#import "CDRSXcodeInterfaces.h"
#import "CDRSXcodeDevToolsInterfaces.h"
#import "SFDYCIXCodeHelper.h"
#import "SFDYCIErrorFactory.h"
#import "SFDYCIClangParamsExtractor.h"
#import "SFDYCIClangParams.h"
#import "DYCI_CCPXCodeConsole.h"
#import "DYCI_CCPShellRunner.h"
#import "DYCI_CCPXCodeConsole.h"


@interface SFDYCIXcodeObjectiveCRecompiler ()

@property(nonatomic, strong) SFDYCIClangParamsExtractor * clangParamsExtractor;

@property(nonatomic, strong) DYCI_CCPXCodeConsole *console;
@end

@implementation SFDYCIXcodeObjectiveCRecompiler

- (id)init {
    self = [super init];
    if (self) {
        self.clangParamsExtractor = [SFDYCIClangParamsExtractor new];
        self.console = [DYCI_CCPXCodeConsole consoleForKeyWindow];
    }
    return self;
}


- (void)recompileFileAtURL:(NSURL *)fileURL completion:(void (^)(NSError *error))completionBlock {

    SFDYCIXCodeHelper *xcode = [SFDYCIXCodeHelper instance];
    XC(PBXTarget) target = [xcode targetInOpenedProjectForFileURL:fileURL];
    if (!target) {
        // TODO : Custom error
        [self failWithError:nil completionBlock:completionBlock];
        [self.console error:@"Cannot find target for specified file"];
        return;
    }

    XC(PBXTargetBuildContext) buildContext = target.targetBuildContext;
    NSArray *commands = nil;
    // Xcode 6.0 ETC
    if ([(id)buildContext respondsToSelector:@selector(commands)]) {
        commands = [buildContext commands];
    } else {
        // Xcode 7.0
        @try {
            [buildContext waitForDependencyGraph];
            [buildContext lockDependencyGraph];
            commands = [[[buildContext dependencyNodeForPath:fileURL.path] consumerCommands] allObjects];
            [buildContext unlockDependencyGraph];
        }
        @catch (NSException *exception) {
            [self.console error:@"Cannot get file relation to the target. Please run project again. ¯\\_(ツ)_/¯"];
        }
    }

    [self.console debug:[NSString stringWithFormat:@"Commands : %@", commands]];

    [commands enumerateObjectsUsingBlock:^(XC(XCDependencyCommand) command, NSUInteger idx, BOOL *stop) {
        [self.console debug:[NSString stringWithFormat:@"Command #%lu of classs %@ : %@", idx, [(id) command class], command ]];

        NSArray *ruleInfo = [command ruleInfo];
        [self.console debug:[NSString stringWithFormat:@"Command : %@", ruleInfo]];
        if ([[ruleInfo firstObject] isEqualToString:@"CompileC"]) {
            /**
            * Commands can contain build rules for multiple file so
            * make sure you got the right one.
            */
            NSString *sourcefile_path = ruleInfo[2];
            if (![sourcefile_path isEqualToString:fileURL.path]) {
                return;
            }

            [self.console debug:[NSString stringWithFormat:@"Found command that was originally created this file. Rerunning it"]];
            [self.console debug:[NSString stringWithFormat:@"We should actually run %@ %@", command.commandPath, command.arguments]];
            [self.console debug:[NSString stringWithFormat:@"Command tool specification : %@", [command toolSpecification]]];

            [self runCompilationCommand:command completion:^(NSError *error) {
                if (error != nil) {
                    completionBlock(error);
                } else {
                    [self createDynamiclibraryWithCommand:command completion:completionBlock];
                }
            }];
            *stop = YES;
            return;

        }

        // Linker arguments
        if ([[ruleInfo firstObject] isEqualToString:@"Ld"]) {
            /*
             * Xcode doesn't pass object files (.o) directly to the linker (it uses
             * a dependency info file instead) so the only thing we can do here is to grab
             * the linker arguments.        [self.console.textStorage beginEditing];

             */
            [self.console debug:[NSString stringWithFormat:@"\nLinker: %@ %@", command.commandPath, command.arguments]];
        }
    }];

}


#pragma mark - Running command

- (void)runCompilationCommand:(id<CDRSXcode_XCDependencyCommand>)command completion:(void (^)(NSError *))completion {

    [self.console debug:[NSString stringWithFormat:@"Task started %@ + %@", command.commandPath, command.arguments]];
    [self.console log:[NSString stringWithFormat:@"Injection started"]];

    [DYCI_CCPShellRunner runShellCommand:command.commandPath
                                withArgs:command.arguments
                               directory:command.workingDirectoryPath
                             environment:[command.environment mutableCopy]
                                 console:self.console
                              completion:completion];

}


#pragma mark - Creating Dylib

- (DYCI_CCPXCodeConsole *)console {
    if (!_console) {
        _console = [DYCI_CCPXCodeConsole consoleForKeyWindow];
    }
    return _console;
}


- (void)createDynamiclibraryWithCommand:(id <CDRSXcode_XCDependencyCommand>)command completion:(void (^)(NSError *))completion {

    void (^safeCompletion)(NSError *) = completion ?: ^(NSError * error){};

    SFDYCIClangParams * clangParams = [self.clangParamsExtractor extractParamsFromArguments:command.arguments];
    [self.console debug:[NSString stringWithFormat:@"Clang params extracted : %@", clangParams]];

    [self.console log:@"Creating Dynamic library..."];

    NSString * libraryName = [NSString stringWithFormat:@"dyci%d.dylib", arc4random_uniform(10000000)];

    /*
     + ["-arch"] + [clangParams['arch']]\
     + ["-dynamiclib"]\
     + ["-isysroot"] + [clangParams['isysroot']]\
     + clangParams['LParams']\
     + clangParams['FParams']\
     + [clangParams['object']]\
     + ["-install_name"] + ["/usr/local/lib/" + libraryName]\
     + ['-Xlinker']\
     + ['-objc_abi_version']\
     + ['-Xlinker']\
     + ["2"]\
     + ["-ObjC"]\
     + ["-undefined"]\
     + ["dynamic_lookup"]\
     + ["-fobjc-arc"]\
     + ["-fobjc-link-runtime"]\
     + ["-Xlinker"]\
     + ["-no_implicit_dylibs"]\
     + [clangParams['minOSParam']]\
     + ["-single_module"]\
     + ["-compatibility_version"]\
     + ["5"]\
     + ["-current_version"]\
     + ["5"]\
     + ["-o"]\
     + [DYCI_ROOT_DIR + "/" + libraryName]
     */
    NSMutableArray * dlybArguments = [NSMutableArray array];
    [dlybArguments addObjectsFromArray:
      @[
        @"-arch", clangParams.arch,
        @"-dynamiclib",
        @"-isysroot", clangParams.isysroot,
      ]
    ];
    [dlybArguments addObjectsFromArray:clangParams.LParams];
    [dlybArguments addObjectsFromArray:clangParams.FParams];

    NSString *outputPath = [[@"~/.dyci" stringByExpandingTildeInPath] stringByAppendingPathComponent:libraryName];
    [dlybArguments addObjectsFromArray:
        @[
            clangParams.objectCompilationPath,
            @"-install_name", [NSString stringWithFormat:@"/usr/local/lib/%@", libraryName],
            @"-Xlinker",
            @"-objc_abi_version",
            @"-Xlinker",
            @"2",
            @"-ObjC",
            @"-undefined",
            @"dynamic_lookup",
            @"-fobjc-arc",
            @"-fobjc-link-runtime",
            @"-Xlinker",
            @"-no_implicit_dylibs",
            clangParams.minOSParams,
            @"-single_module",
            @"-compatibility_version",
            @"5",
            @"-current_version",
            @"5",
            @"-o",
            outputPath
            //, @"-v"
        ]
    ];


    DYCI_CCPXCodeConsole *console = [DYCI_CCPXCodeConsole consoleForKeyWindow];
    [console debug:[NSString stringWithFormat:@"Task started %@ + %@", command.commandPath, dlybArguments]];

    [DYCI_CCPShellRunner runShellCommand:command.commandPath
                                withArgs:dlybArguments
                               directory:command.workingDirectoryPath
                             environment:[command.environment mutableCopy]
                                 console:self.console
                              completion:^(NSError *error) {
                                  if (error) {
                                      safeCompletion(error);
                                      return;
                                  }

                                  [DYCI_CCPShellRunner runShellCommand:@"/usr/bin/codesign"
                                                              withArgs:@[@"--force", @"--sign", @"-", outputPath]
                                                             directory:command.workingDirectoryPath
                                                           environment:[command.environment mutableCopy]
                                                               console:self.console
                                                            completion:^(NSError *error2) {
                                                                safeCompletion(error2);
                                                            }];

;

                              }];

}


#pragma mark - Compilation

- (void)failWithError:(NSError *)error completionBlock:(void (^)(NSError *))block {
  if (block) {
      block(error);
  }
}


#pragma mark - SFDYCIRecompilerProtocol

- (BOOL)canRecompileFileAtURL:(NSURL *)fileURL {
    NSString * filePath = [fileURL absoluteString];
    if ([[filePath pathExtension] isEqualToString:@"h"]) {
        filePath = [[filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"m"];
    }

    if ([[filePath pathExtension] isEqualToString:@"m"] || [[filePath pathExtension] isEqualToString:@"mm"]) {
        SFDYCIXCodeHelper *xcode = [SFDYCIXCodeHelper instance];
        XC(PBXTarget) target = [xcode targetInOpenedProjectForFileURL:fileURL];
        if (!target) {
            return NO;
        }
        return YES;
    }

    return NO;
}

@end
