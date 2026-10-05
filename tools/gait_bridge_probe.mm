#import <Foundation/Foundation.h>

#import "ChicaGaitEngineBridge.h"

#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

int javaGait(int apkGait)
{
    if (apkGait >= 5 && apkGait <= 10) return apkGait;
    switch (apkGait) {
        case 9: return 2;
        case 6: return 3;
        case 7: return 4;
        default: return 1;
    }
}

std::vector<std::string> split(const std::string& value)
{
    std::stringstream input(value);
    std::vector<std::string> parts;
    std::string part;
    while (std::getline(input, part, ',')) parts.push_back(part);
    return parts;
}

void printPulses(NSArray<NSNumber *> *pulses)
{
    std::cout << "[";
    for (NSUInteger index = 0; index < pulses.count; ++index) {
        if (index != 0) std::cout << ",";
        std::cout << pulses[index].intValue;
    }
    std::cout << "]\n";
}

} // namespace

int main(int argc, char **argv)
{
    @autoreleasepool {
        ChicaGaitEngineBridge *engine = [[ChicaGaitEngineBridge alloc] init];
        [engine enterNeutralPoseWithBodyZ:40.0];
        for (int index = 1; index < argc; ++index) {
            if (std::string(argv[index]) != "--frame" || index + 1 >= argc) continue;
            std::vector<std::string> parts = split(argv[++index]);
            if (parts.size() != 7) return 2;
            int gait = std::stoi(parts[0]);
            int animation = std::stoi(parts[1]);
            double dt = std::stod(parts[2]);
            bool allow = std::stoi(parts[3]) != 0;
            NSArray<NSNumber *> *pulses = [engine stepWithGait:javaGait(gait)
                                                        animation:animation
                                                          forward:std::stod(parts[4])
                                                           strafe:std::stod(parts[5])
                                                             turn:std::stod(parts[6])
                                                          deltaMs:dt
                                                   allowNewAnchors:allow];
            printPulses(pulses);
        }
    }
    return 0;
}
