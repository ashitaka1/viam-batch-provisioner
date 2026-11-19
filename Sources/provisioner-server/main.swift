import Foundation
import ProvisionerServer

ServerMain.bootstrapLogging()
exit(await ServerMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
