import Foundation
import Vapor
import SwiftPFor2D
import SwiftNetCDF


/// Download MetNo domains from OpenDAP server
struct MetNoDownloader: AsyncCommandFix {
    struct Signature: CommandSignature {
        @Argument(name: "domain")
        var domain: String

        @Option(name: "run")
        var run: String?
        
        @Option(name: "past-days")
        var pastDays: Int?

        @Flag(name: "skip-existing")
        var skipExisting: Bool
        
        @Flag(name: "create-netcdf")
        var createNetcdf: Bool
        
        @Option(name: "only-variables")
        var onlyVariables: String?
    }

    var help: String {
        "Download MetNo models"
    }
    
    func run(using context: CommandContext, signature: Signature) async throws {
        let start = DispatchTime.now()
        let logger = context.application.logger
        guard let domain = MetNoDomain.init(rawValue: signature.domain) else {
            fatalError("Invalid domain '\(signature.domain)'")
        }
        let run = signature.run.map {
            guard let run = Int($0) else {
                fatalError("Invalid run '\($0)'")
            }
            return run
        } ?? domain.lastRun
        
        let onlyVariables: [MetNoVariable]? = signature.onlyVariables.map {
            $0.split(separator: ",").map {
                guard let variable = MetNoVariable(rawValue: String($0)) else {
                    fatalError("Invalid variable '\($0)'")
                }
                return variable
            }
        }
        
        let variables = onlyVariables ?? MetNoVariable.allCases
        
        let date = Timestamp.now().add(-24*3600 * (signature.pastDays ?? 0)).with(hour: run)
        
        logger.info("Downloading domain '\(domain.rawValue)' run '\(date.iso8601_YYYY_MM_dd_HH_mm)'")
        
        try FileManager.default.createDirectory(atPath: domain.downloadDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: domain.omfileDirectory, withIntermediateDirectories: true)
        
        //try await download(application: context.application, domain: domain, run: date, skipFilesIfExisting: signature.skipExisting)
        try convert(logger: logger, domain: domain, variables: variables, run: date, createNetcdf: signature.createNetcdf)
        logger.info("Finished in \(start.timeElapsedPretty())")
    }
    
    /// Process each variable and update time-series optimised files
    func convert(logger: Logger, domain: MetNoDomain, variables: [MetNoVariable], run: Timestamp, createNetcdf: Bool) throws {
        let om = OmFileSplitter(basePath: domain.omfileDirectory, nLocations: domain.grid.count, nTimePerFile: domain.omFileLength, yearlyArchivePath: nil)
        
        let openDap = "https://thredds.met.no/thredds/dodsC/metpplatest/met_forecast_1_0km_nordic_\(run.format_YYYYMMdd)T\(run.hour)Z.nc"
        
        let ncFile = try NetCDF.openOrWait(path: openDap, deadline: Date().addingTimeInterval(3600), logger: logger)
        let dimensions = ncFile.getDimensions()
        guard dimensions.count == 3 else {
            fatalError("Expected 3 dimensions, got \(dimensions.count)")
        }
        let nx = dimensions.first(where: {$0.name == "x"})!.length
        let ny = dimensions.first(where: {$0.name == "y"})!.length
        let nTime = dimensions.first(where: {$0.name == "time"})!.length
        
        guard nx == domain.grid.nx, ny == domain.grid.ny else {
            fatalError("Wrong domain dimensions \(nx), \(ny)")
        }
        guard (58...64).contains(nTime) else {
            fatalError("Wrong time dimensions \(nTime)")
        }
        
        /// Create elevation file if requried
        if !FileManager.default.fileExists(atPath: domain.surfaceElevationFileOm) {
            logger.info("Creating elevation file")
            // unit meters
            guard var altitude = try ncFile.getVariable(name: "altitude")?.asType(Float.self)?.read() else {
                fatalError("Could not get float data from altitude")
            }
            // units 0=sea, 1=land
            guard let land_area_fraction = try ncFile.getVariable(name: "land_area_fraction")?.asType(Float.self)?.read() else {
                fatalError("Could not get float data from altitude")
            }
            for i in altitude.indices {
                if land_area_fraction[i] < 0.5 {
                    altitude[i] = -999
                }
            }
            logger.info("Writing elevation file")
            try OmFileWriter(dim0: ny, dim1: nx, chunk0: 20, chunk1: 20).write(file: domain.surfaceElevationFileOm, compressionType: .p4nzdec256, scalefactor: 1, all: altitude)
        }
        
        let ringtime = run.timeIntervalSince1970 / domain.dtSeconds ..< run.timeIntervalSince1970 / domain.dtSeconds + nTime
        
        for variable in variables {
            logger.info("Converting \(variable)")
            let startConvert = DispatchTime.now()
            
            // Transpose to fast time. Closure is used to free up some memory.
            var data2d = try {
                guard let ncVar = ncFile.getVariable(name: variable.netCdfName) else {
                    fatalError("Could not open nc variable \(variable) \(variable.netCdfName)")
                }
                guard let data = try ncVar.asType(Float.self)?.read() else {
                    fatalError("Could not get float data from \(variable)")
                }
                return Array2DFastSpace(data: data, nLocations: nx*ny, nTime: nTime).transpose()
            }()
            
            // Scaling
            if let fma = variable.multiplyAdd {
                data2d.data.multiplyAdd(multiply: fma.multiply, add: fma.add)
            }
            
            let skip = variable.skipHour0 ? 1 : 0
            
            if variable.isAccumulatedSinceModelStart {
                data2d.deaccumulateOverTime(slidingWidth: data2d.nTime, slidingOffset: skip)
            }
            
            if createNetcdf {
                try data2d.transpose().writeNetcdf(filename: "\(domain.downloadDirectory)\(variable.omFileName).nc", nx: nx, ny: ny)
            }
            
            logger.info("Reading and interpolation done in \(startConvert.timeElapsedPretty()). Starting om file update")
            let startOm = DispatchTime.now()
            try om.updateFromTimeOriented(variable: variable.omFileName, array2d: data2d, ringtime: ringtime, skipFirst: skip, smooth: 0, skipLast: 0, scalefactor: variable.scalefactor)
            logger.info("Update om finished in \(startOm.timeElapsedPretty())")
        }
    }
}


fileprivate extension NetCDF {
    /// Try to open a file. If it does not excist, wait 10 seconds and try again until deadline is reached
    /// Works with OpenDap urls
    static func openOrWait(path: String, deadline: Date, logger: Logger) throws -> Group {
        let startTime = Date()
        var lastPrint = Date().addingTimeInterval(TimeInterval(-60))
        let retySeconds = 10
        
        while true {
            guard let nc = try openCatchMssing(path: path, allowUpdate: false) else {
                let timeElapsed = Date().timeIntervalSince(startTime)
                if Date().timeIntervalSince(lastPrint) > 60 {
                    logger.info("NetCDF open failed, retry every \(retySeconds) seconds, (\(Int(timeElapsed/60)) minutes elapsed")
                    lastPrint = Date()
                }
                if Date() > deadline {
                    logger.error("Deadline reached")
                    throw CurlError.timeoutReached
                }
                sleep(UInt32(retySeconds))
                continue
            }
            return nc
        }
    }
    
    /// Try to open a file, but catch error "file not found"
    static func openCatchMssing(path: String, allowUpdate: Bool) throws -> Group? {
        do {
            return try open(path: path, allowUpdate: allowUpdate)
        } catch (NetCDFError.ncerror(code: let code, error: let error)) {
            if error == "NetCDF: file not found" {
                return nil
            }
            throw NetCDFError.ncerror(code: code, error: error)
        }
    }
}

extension Group {
    /// Recursively print all groups
    func dump() {
        print("Group: \(name)")
        
        for d in getDimensions() {
            print("Dimension: \(d.name) \(d.length) \(d.isUnlimited)")
        }
        
        for v in getVariables() {
            print("Variable: \(v.name) \(v.type.asExternalDataType()!)")
            for d in v.dimensions {
                print("Variable dimension: \(d.name) \(d.length) \(d.isUnlimited)")
            }
        }
        
        for a in try! getAttributes() {
            print("Attribute: \(a.name) \(a.length) \(a.type.asExternalDataType()!)")
        }
        
        for subgroup in getGroups() {
            subgroup.dump()
        }
    }
}