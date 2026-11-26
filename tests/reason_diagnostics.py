"""Run production Foundation reason formatting on the GitHub macOS runner.

Only the actual formatter functions are extracted, without UIKit or hooks.
No formatter implementation is duplicated in this regression check.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'QualityLab.m').read_text()
begin = source.index('static BOOL reasonToken(')
end = source.index('static void observePlaybackError(', begin)
formatter = source[begin:end]
prefix = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
static NSMutableArray<NSString *> *records;
static void recordState(NSString *key, NSString *line) { [records addObject:line]; }
static void require(BOOL passed, NSString *message) {
    if (!passed) { fprintf(stderr, "FAIL: %s\n",message.UTF8String); exit(1); }
}
static NSString *output(void) { return [records componentsJoinedByString:@"\n"]; }
'''
main = r'''
int main(void) {
    @autoreleasepool {
        records=NSMutableArray.new;
        // Reproduces the one-element NSSet seen in the actual iPhone log.
        observeReasonValue([NSSet setWithObject:@"premium_required"],@"fixture",@"disallow",0);
        require([output() containsString:@"set_count=1"],@"singleton NSSet was not recognized");
        require([output() containsString:@"premium_required"],@"singleton NSSet reason was lost");
        require(![output() containsString:@"unsupported_class"],@"NSSet remains unsupported");

        [records removeAllObjects];
        observeReasonValue([NSSet setWithObject:@101],@"fixture",@"disallow",0);
        require([output() containsString:@"=101"],@"numeric set reason was lost");

        [records removeAllObjects];
        observeReasonValue(@{@"reasons":[NSSet setWithObject:@"format_unavailable"],
                             @"track_uri":@"spotify:track:PRIVATE_URI",
                             @"access_token":@"PRIVATE_TOKEN"},@"fixture",@"disallow",0);
        require([output() containsString:@"format_unavailable"],@"nested set reason was lost");
        require(![output() containsString:@"PRIVATE"],@"identifier or credential was exported");

        [records removeAllObjects];
        observeReasonValue(@[@"track_unavailable",@"https://private.example/secret"],@"fixture",@"disallow",0);
        require([output() containsString:@"track_unavailable"],@"array reason regressed");
        require(![output() containsString:@"private.example"],@"raw URL was exported");
        puts("PASS: singleton set, numeric set, nested set privacy, and array compatibility");
    }
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='qualitylab-reasons-') as temporary:
    folder = Path(temporary)
    objective_c = folder / 'reason_check.m'
    executable = folder / 'reason_check'
    objective_c.write_text(prefix + formatter + main)
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks',
                    '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-framework', 'Foundation', str(objective_c), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
