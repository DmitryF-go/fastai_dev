/*
THIS FILE WAS AUTOGENERATED! DO NOT EDIT!
file to edit: 04_callbacks.ipynb

*/
        
import Path
import TensorFlow

public struct BasicModel: Layer {
    public var layer1: Dense<Float>
    public var layer2: Dense<Float>
    
    public init(nIn: Int, nHid: Int, nOut: Int){
        layer1 = Dense(inputSize: nIn, outputSize: nHid, activation: relu)
        layer2 = Dense(inputSize: nHid, outputSize: nOut)
    }
    
    @differentiable
    public func applied(to input: Tensor<Float>) -> Tensor<Float> {
        return input.sequenced(through: layer1, layer2)
    }
}

public struct DataBunch<Element> where Element: TensorGroup{
    public var _train: Dataset<Element>
    public var _valid: Dataset<Element>
    public var shuffleTrain: Bool = true
    public var shuffleValid: Bool = false
    public var batchSize: Int = 64 
    public var train: Dataset<Element> { return processDs(_train, shuffleTrain) }
    public var valid: Dataset<Element> { return processDs(_valid, shuffleValid) }
    
    private func processDs(_ ds: Dataset<Element>, _ shuffle: Bool) -> Dataset<Element>{
        if !shuffle { return ds.batched(Int64(batchSize))}
        let count = Int64(500000)  // A very large number
        return ds.shuffled(sampleCount: count, randomSeed: Int64.random(in: Int64.min..<Int64.max)).batched(Int64(batchSize))
    }
    
    public init(train: Dataset<Element>, valid: Dataset<Element>, batchSize: Int = 64) {
        (self._train, self._valid, self.batchSize)  = (train, valid, batchSize)
    }
}

public func mnistDataBunch(path: Path = mnistPath, flat: Bool = false, bs: Int = 64
                          ) -> DataBunch<DataBatch<TF, TI>>{
    let (xTrain,yTrain,xValid,yValid) = loadMNIST(path: path, flat: flat)
    return DataBunch(train: Dataset(elements:DataBatch(xb:xTrain, yb:yTrain)), 
                     valid: Dataset(elements:DataBatch(xb:xValid, yb:yValid)),
                     batchSize: bs)
}

public enum LearnerAction: Error {
    case skipEpoch
    case skipBatch
    case stop
}

/// A model learner, responsible for initializing and training a model on a given dataset.
public final class Learner<Label: TensorGroup,
                           Opt: TensorFlow.Optimizer & AnyObject>
    where Opt.Scalar: Differentiable,
          // Constrain model input to Tensor<Float>, to work around
          // https://forums.fast.ai/t/fix-ad-crash-in-learner/42970.
          Opt.Model.Input == Tensor<Float>
{
    // Common type aliases.
    public typealias Input = Model.Input
    public typealias Data = DataBunch<DataBatch<Input, Label>>
    public typealias Loss = Tensor<Float>
    public typealias Optimizer = Opt
    public typealias Model = Optimizer.Model
    public typealias Variables = Model.AllDifferentiableVariables
    public typealias EventHandler = (Learner) throws -> Void
    
    /// A wrapper class to hold the loss function, to work around
    // https://forums.fast.ai/t/fix-ad-crash-in-learner/42970.
    public final class LossFunction {
        public typealias F = @differentiable (Model.Output, @nondiff Label) -> Loss
        public var f: F
        init(_ f: @escaping F) { self.f = f }
    }
    
    /// The dataset on which the model will be trained.
    public var data: Data
    /// The optimizer used for updating model parameters along gradient vectors.
    public var optimizer: Optimizer
    /// The function that computes a loss value when given a prediction and a label.
    public var lossFunction: LossFunction
    /// The model being trained.
    public var model: Model
    
    //Is there a better way to initialize those to not make them Optionals?
    public var currentInput: Input? = nil
    public var currentTarget: Label? = nil
    public var currentOutput: Model.Output? = nil
    
    /// The number of total epochs.
    public private(set) var epochCount: Int = .zero
    /// The current epoch.
    public private(set) var currentEpoch: Int = .zero
    /// The current gradient.
    public private(set) var currentGradient: Model.CotangentVector = .zero
    /// The current loss.
    public private(set) var currentLoss: Loss = .zero
    /// In training mode or not
    public private(set) var inTrain: Bool = false
    /// The current epoch + iteration, float between 0.0 and epochCount
    public private(set) var pctEpochs: Float = 0.0
    /// The current iteration
    public private(set) var currentIter: Int = 0
    /// The number of iterations in the current dataset
    public private(set) var iterCount: Int = 0
    
    open class Delegate {
        open var order: Int { return 0 }
        public init () {}
        
        open func trainingWillStart(learner: Learner) throws {}
        /// The completion of model training.
        open func trainingDidFinish(learner: Learner) throws {}
        /// A closure which will be called upon the start of an epoch.
        open func epochWillStart(learner: Learner) throws {}
        /// A closure which will be called upon the completion of an epoch.
        open func epochDidFinish(learner: Learner) throws {}
        /// A closure which will be called upon the start of model validation.
        open func validationWillStart(learner: Learner) throws {}
        /// A closure which will be called upon the start of training on a batch.
        open func batchWillStart(learner: Learner) throws {}
        /// A closure which will be called upon the completion of training on a batch.
        open func batchDidFinish(learner: Learner) throws {}
        /// A closure which will be called when a new gradient has been computed.
        open func didProduceNewGradient(learner: Learner) throws {}
        /// A closure which will be called upon the completion of an optimizer update.
        open func optimizerDidUpdate(learner: Learner) throws {}
        ///
        /// TODO: learnerDidProduceNewOutput and learnerDidProduceNewLoss need to
        /// be differentiable once we can have the loss function inside the Learner
    }
    
    public var delegates: [Delegate] = [] {
        didSet { delegates.sort { $0.order < $1.order } }
    }
    
    /// Creates a learner.
    ///
    /// - Parameters:
    ///   - data: The databunch used for training and validation.
    ///   - lossFunction: The loss function.
    ///   - optimizer: The optimizer used for updating model parameters.
    ///   - modelInitializer: The closure that produces the model to be trained.
    public init(data: Data,
                lossFunction: @escaping LossFunction.F,
                optimizer: Optimizer,
                initializingWith modelInitializer: () -> Model) {
        self.data = data
        self.optimizer = optimizer
        self.lossFunction = LossFunction(lossFunction)
        self.model = modelInitializer()
    }
}

extension Learner {
    /// Trains the model on the given batch.
    ///
    /// - Parameter batch: The batch of input data and labels to be trained on.
    ///
    private func evaluate(onBatch batch: DataBatch<Input, Label>) throws {
        currentOutput = model.applied(to: currentInput!)
        currentLoss = lossFunction.f(currentOutput!, currentTarget!)
    }
    
    private func train(onBatch batch: DataBatch<Input, Label>) throws {
        let (xb,yb) = (currentInput!,currentTarget!)
        (currentLoss, currentGradient) = model.valueWithGradient { model -> Loss in 
            let y = model.applied(to: xb)                                      
            currentOutput = y
            return lossFunction.f(y, yb)
        }
        try delegates.forEach { try $0.didProduceNewGradient(learner: self) }
        optimizer.update(&model.allDifferentiableVariables, along: self.currentGradient)
    }
    
    /// Performs a training epoch on a Dataset.
    private func train(onDataset ds: Dataset<DataBatch<Input, Label>>) throws {
        iterCount = ds.count(where: {_ in true})
        for batch in ds {
            (currentInput, currentTarget) = (batch.xb, batch.yb)
            try delegates.forEach { try $0.batchWillStart(learner: self) }
            do { if inTrain { try train(onBatch: batch) } else { try evaluate(onBatch: batch) }}
            catch LearnerAction.skipBatch {}
            try delegates.forEach { try $0.batchDidFinish(learner: self) }
        }
    }
}

extension Learner {
    /// Starts fitting.
    /// - Parameter epochCount: The number of epochs that will be run.
    public func fit(_ epochCount: Int) throws {
        self.epochCount = epochCount
        do {
            try delegates.forEach { try $0.trainingWillStart(learner: self) }
            for i in 0..<epochCount {
                self.currentEpoch = i
                do {
                    try delegates.forEach { try $0.epochWillStart(learner: self) }
                    do { try train(onDataset: data.train) }
                    try delegates.forEach { try $0.validationWillStart(learner: self) }
                    do { try train(onDataset: data.valid) }
                    
                } catch LearnerAction.skipEpoch {}
                try delegates.forEach { try $0.epochDidFinish(learner: self) }
            }
        } catch LearnerAction.stop {}
        try delegates.forEach { try $0.trainingDidFinish(learner: self) }
    }
}

public extension Learner {
    func addDelegate(_ delegate: Learner.Delegate) {
        delegates.append(delegate)
    }
    
    func addDelegates(_ delegates: [Learner.Delegate]) {
        self.delegates += delegates
    }
}

extension Learner {
    public class TrainEvalDelegate: Delegate {
        public override func trainingWillStart(learner: Learner) {
            learner.pctEpochs = 0.0
        }

        public override func epochWillStart(learner: Learner) {
            Context.local.learningPhase = .training
            learner.pctEpochs = Float(learner.currentEpoch)
            learner.inTrain = true
            learner.currentIter = 0
        }
        
        public override func batchDidFinish(learner: Learner) {
            learner.currentIter += 1
            if learner.inTrain{ learner.pctEpochs += 1.0 / Float(learner.iterCount) }
        }
        
        public override func validationWillStart(learner: Learner) {
            Context.local.learningPhase = .inference
            learner.inTrain = false
            learner.currentIter = 0
        }
    }
    
    public func makeTrainEvalDelegate() -> TrainEvalDelegate { return TrainEvalDelegate() }
}

// TODO: make metrics more generic (probably for after the course)
extension Learner {
    public class AvgMetric: Delegate {
        public let metrics: [(TF,TI) -> TF]
        var total: Int = 0
        var partials: [TF] = []
        
        public init(metrics: [(TF, TI) -> TF]){ self.metrics = metrics}
        
        public override func epochWillStart(learner: Learner) {
            total = 0
            partials = Array(repeating: Tensor(0), count: metrics.count + 1)
        }
        
        public override func batchDidFinish(learner: Learner) {
            if !learner.inTrain{
                if let target = learner.currentTarget as? TI{
                    let bs = target.shape[0]
                    total += bs
                    partials[0] += Float(bs) * learner.currentLoss
                    for i in 1...metrics.count{
                        partials[i] += Float(bs) * metrics[i-1]((learner.currentOutput as! TF), target)
                    }
                }
            }
        }
        
        public override func epochDidFinish(learner: Learner) {
            for i in 0...metrics.count {partials[i] = partials[i] / Float(total)}
            print("Epoch \(learner.currentEpoch): \(partials)")
        }
    }
    
    public func makeAvgMetric(metrics: [(TF,TI) -> TF]) -> AvgMetric{
        return AvgMetric(metrics: metrics)
    }
}

extension Learner {
    public class Normalize: Delegate {
        public let mean, std: TF
        public init(mean: TF, std: TF){ 
            (self.mean,self.std) = (mean,std)
        }
        
        public override func batchWillStart(learner: Learner) {
            learner.currentInput = (learner.currentInput! - mean) / std
        }
    }
    
    public func makeNormalize(mean: TF, std: TF) -> Normalize{
        return Normalize(mean: mean, std: std)
    }
}

public let mnistStats = (mean: TF(0.13066047), std: TF(0.3081079))
