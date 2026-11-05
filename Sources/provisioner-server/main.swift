import Foundation
import ProvisionerServer

exit(await ServerMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
