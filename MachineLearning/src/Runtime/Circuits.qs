// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

namespace Microsoft.Quantum.MachineLearning {
	open Microsoft.Quantum.Math;
	open Microsoft.Quantum.Arrays;
	open Microsoft.Quantum.Arithmetic;
	open Microsoft.Quantum.Canon;
	open Microsoft.Quantum.Intrinsic;
	open Microsoft.Quantum.Convert;
	open Microsoft.Quantum.Diagnostics;
	open Microsoft.Quantum.Preparation;
	open Microsoft.Quantum.Characterization;

	/// WARNING: the downstream EstimateFrequencyA counts the frequency of Zero

	operation measureLastQubit(nQubits : Int): (Qubit[] => Result) {
		let paulis = ConstantArray(nQubits, PauliI) w/ (nQubits - 1) <- PauliZ;
		return Measure(paulis, _);
	}

	operation _endToEndPreparation(enc: (LittleEndian => Unit is Adj + Ctl), parameters: Double[], gates: GateSequence, reg: Qubit[]): Unit is Adj
	{
		enc(LittleEndian(reg));
		_ApplyGates(parameters, gates, reg);
	}

	operation endToEndPreparation(enc: (LittleEndian => Unit is Adj + Ctl), parameters: Double[], gates: GateSequence) : (Qubit[] => Unit is Adj)
	{
		return _endToEndPreparation(enc,parameters, gates, _);
	}

	function collectNegativeLocs(cNegative: Int, coefficients : ComplexPolar[]) : Int[]
	{
		mutable negLocs = ConstantArray(cNegative, -1);
		mutable nlx = 0;
		for (idx in 0 .. Length(coefficients) - 1)
        {
			let (r,a) = (coefficients[idx])!;
			if (AbsD(a - PI()) <  1E-9) {
				if (nlx < cNegative)
				{
					set negLocs w/= nlx <- idx;
					set nlx = nlx+1;
				}
			}
        }
		return negLocs;
	} //collectNegativeLocs

	// NOTE: the last qubit of 'reg' in this context is the auxillary qubit used in the Hadamard test.
	operation _endToEndHTcircuit(enc: (LittleEndian => Unit is Adj + Ctl), param1 : Double[], gates1: GateSequence, param2 : Double[], gates2: GateSequence, reg: Qubit[]): Unit is Adj + Ctl {
        let L = Length(reg) - 1;
        let g1 = _ApplyGates(param1,gates1,_);
        let g2 = _ApplyGates(param2,gates2,_);

        enc(LittleEndian(reg[0..(L-1)]));
		within {
			H(Tail(reg));
		} apply {
			(Controlled g1) ([reg[L]], reg[0..(L-1)]);
			within {
				X(Tail(reg));
			} apply {
				(Controlled g2) ([reg[L]], reg[0..(L-1)]);
				(Controlled Z)  ([reg[L]], reg[(L-1)]);
			}
		}
    }

	operation endToEndHTcircuit(enc: (LittleEndian => Unit is Adj + Ctl),param1 : Double[], gates1: GateSequence, param2 : Double[], gates2: GateSequence) : (Qubit[] => Unit is Adj) {
		return _endToEndHTcircuit(enc,param1, gates1, param2, gates2, _);
	}

	operation HardamardTestPhysical(enc2: (LittleEndian => Unit is Adj + Ctl), param1 : Double[], gates1: GateSequence, param2 : Double[], gates2: GateSequence, nQubits: Int, nMeasurements : Int): Double
	{
		return 1.0-EstimateFrequencyA(endToEndHTcircuit(enc2,param1,gates1,param2,gates2),measureLastQubit(nQubits), nQubits, nMeasurements);
	}

	operation QubitProbPhysical(enc: (LittleEndian => Unit is Adj + Ctl), parameters: Double[], gates: GateSequence, nQubits: Int, nMeasurements : Int)
	: Double {
		return 1.0 - EstimateFrequencyA(
			endToEndPreparation(enc,parameters,gates),
			measureLastQubit(nQubits),
			nQubits,
			nMeasurements
		);
	}

	operation CircuitResultClassical(tolerance: Double, parameters : Double[], gates: GateSequence, sample: Double[], nMeasurements: Int) : Double
	{
		let dL = IntAsDouble (Length(sample));
		let N = Microsoft.Quantum.Math.Ceiling(Lg(dL));
		let circEnc = NoisyInputEncoder(tolerance/IntAsDouble(Length(gates!)),sample);
		let rslt = QubitProbPhysical(circEnc, parameters,gates, N, nMeasurements);
		return rslt;

	}


	/// # Summary
	/// Classify one sample;  the label part of the container is ignored
	///
	/// # Input
	/// ## measCount
	/// the number of measurements used
	///
	/// ## sg
	/// generates quantum encoding of a subject sample (either simulated or true)
	///
	/// ## param
	/// circuit parameters
	///
	/// ## gates
	/// sequence of gates in the circuit
	///
	/// ## bias
	/// postselection bias of the model
	///
	/// # Output
	/// post-selected class label
	///
	operation ClassifyOneSimulated(tolerance: Double, sample: LabeledSample, parameters : Double[], gates: GateSequence, bias: Double, nMeasurements: Int): Int
	{
		let dL = IntAsDouble (Length(getData(sample)));
		mutable N = Microsoft.Quantum.Math.Ceiling(Lg(dL));
		let qsp = qubitSpan(gates);
		if (N < qsp)
		{
			set N = qsp;
		}
		let circEnc = NoisyInputEncoder(tolerance/IntAsDouble(Length(gates!)), getData(sample));
		return bias + QubitProbPhysical(circEnc, parameters, gates, N, nMeasurements) > 0.5 ? 1 | 0;
	}


	/// # Summary
	/// Quantum-lawful estimation of postselection probability of |1>
	///
	/// # Input
	/// ## measCount
	/// the number of measurements used
	///
	/// ## sg
	/// generates quantum encoding of a subject sample (either simulated or true)
	///
	/// ## param
	/// circuit parameters
	///
	/// ## gates
	/// sequence of gates in the circuit
	///
	/// # Output
	/// the probability estimate
	///
	operation CircuitResult (measCount: Int, sg: StateGenerator, parameters : Double[], gates: GateSequence) : Double {

			mutable countOne = 0.0;
			mutable qCount = qubitSpan(gates);
			if (qCount < Fst(sg!))
			{
				set qCount = Fst(sg!);
			}
			let measIdx = qCount - 1;
			let circEnc = Snd(sg!);
			for (ep in 1..measCount)
			{
				using (qubits = Qubit[qCount])
				{
					//let circEnc = InputEncoder(coefficients); //usage insights
					//let qubitsBE = LittleEndian(qubits);
					circEnc(LittleEndian(qubits));
					_ApplyGates(parameters, gates, qubits);
					//dumpRegisterToConsole(qubits);

					let rslt = M(qubits[measIdx]);
					if (rslt == One)
					{
						set countOne = countOne + 1.0;
					}

					for(i in 0..qCount-1)
					{
						Set(Zero, qubits[i]);
					}
				}
			}

			// Return number of times we saw a |1>
            return countOne/IntAsDouble (measCount);

    }

	/// # Summary
	/// Classify one sample represented as a state generator
	///
	/// # Input
	/// ## measCount
	/// the number of measurements used
	///
	/// ## sg
	/// generates quantum encoding of a subject sample (either simulated or true)
	///
	/// ## param
	/// circuit parameters
	///
	/// ## gates
	/// sequence of gates in the circuit
	///
	/// ## bias
	/// postselection bias of the model
	///
	/// # Output
	/// post-selected class label
	///
	operation ClassifyOne (measCount: Int, sg: StateGenerator, parameters : Double[], gates: GateSequence, bias: Double) : (Int)
	{
		return CircuitResult(measCount,sg,parameters,gates)+bias > 0.5 ? 1 | 0;
	}


	/// # Summary
	/// polymorphic classical/quantum gradient estimator
	///
	/// # Input
	/// ## param
	/// circuit parameters
	///
	/// ## gates
	/// sequence of gates in the circuits
	///
	/// ## sg
	/// generates quantum encoding of a subject sample (either simulated or true)
	///
	/// ## measCount
	/// number of true quantum measurements to estimate probabilities.
	/// IMPORTANT: measCount==0 implies simulator deployment
	///
	/// # Output
	/// the gradient
	///
	operation EstimateGradient(param : Double[], gates: GateSequence, sg: StateGenerator, nMeasurements : Int) : (Double[]) {
		//Synopsis: Suppose (param,gates) define Circ0
		//Suppose (param1,gates1) define Circ1 that implements one-gate derivative of Circ0
		//The expectation derivative is then 2 Re[<Circ1 psi|\Pi_1|Circ0 psi>] =
		// Re[<Circ1 psi|Id|Circ0 psi>] - Re[<Circ1 psi|Z \otimes Id|Circ0 psi>]
		//We observe SEE THEORY that for (Circ1)=(Circ0)' ,  Re[<Circ1 psi|Circ0 psi>]==0
		//Thus we are left to compute Re[<Circ1 psi|Z \otimes Id|Circ0 psi>] =
		// 1 - 1/2 < (Z \otimes Id) Circ0 psi - Circ1 psi | (Z \otimes Id) Circ0 psi - Circ1 psi>
		//i.e., 1 - HadamardTestResultHack(Circ1,[Z],Circ0)


		//Now, suppose a gate at which we differentiate is the (Controlled R(\theta))([k0,k1,...,kr],[target])
		//and we want a unitary description of its \theta-derivative. It can be written as
		// 1/2 {(Controlled R(\theta'))([k0,k1,...,kr],[target]) -  (Controlled Z)([k1,...,kr],[k0])(Controlled R(\theta'))([k0,k1,...,kr],[target])}
		let pC = Length(param);
		mutable grad = ConstantArray(pC, 0.0);
		mutable paramShift = param + [0.0];
		// let sqNorm0 = CircuitResultHack(param, gates, register);
		let nQubits = MaxI(NQubitsRequired(gates), sg::NQubits);

		for (gate in gates!) {
			set paramShift w/= gate::Index <- (param[gate::Index] + PI()); //Shift the corresponding parameter
			// NB: This the *antiderivative* of the bracket
			let newDer = 2.0 * HardamardTestPhysical(
				sg::Apply, param, gates, paramShift, gates, nQubits + 1, nMeasurements
			) - 1.0;
			if (IsEmpty(gate::Span::ControlIndices)) {
				//uncontrolled gate
				set grad w/= gate::Index <- grad[gate::Index] + newDer;
			} else {
				//controlled gate
				set paramShift w/=gate::Index<-(param[gate::Index]+3.0 * PI());
				//Assumption: any rotation R has the property that R(\theta+2 Pi)=(-1).R(\theta)
				// NB: This the *antiderivative* of the bracket
				let newDer1 = 2.0 * HardamardTestPhysical(
					sg::Apply, param, gates, paramShift, gates, nQubits + 1,
					nMeasurements
				) - 1.0;
				set grad w/= gate::Index <- (grad[gate::Index] + 0.5* (newDer - newDer1));
				set paramShift w/= gate::Index <-( param[gate::Index] + PI()); //unshift by 2 Pi (for debugging purposes)
			}
			set paramShift w/= gate::Index <- param[gate::Index]; //unshift this parameter
		}
		return grad;

	} //GradientHack


	/// # Summary
	/// computes stochastic gradient on one classical sample
	///
	/// # Input
	/// ## param
	/// circuit parameters
	///
	/// ## gates
	/// sequence of gates in the circuits
	///
	/// ## sample
	/// sample vector as a raw array
	///
	/// ## nMeasurements
	/// number of true quantum measurements to estimate probabilities
	///
	/// # Output
	/// the gradient
	///
	operation EstimateGradientFromClassicalSample(tolerance: Double, param : Double[], gates: GateSequence, sample: Double[], nMeasurements : Int) : (Double[]) {
		let nQubits = MaxI(FeatureRegisterSize(sample), NQubitsRequired(gates));
		let circEnc = NoisyInputEncoder(tolerance / IntAsDouble(Length(gates!)), sample);
		let sg = StateGenerator(nQubits, circEnc);
		return EstimateGradient(param, gates, sg, nMeasurements);
	}

	//Csharp-frendly adapter for gradient estimation
	//'gates' is a array of "flattened" controlled rotation defitions
	//each such definition is Int[no.controls+3] in the format [parameter index, Pauli index, target index <,control qubit indices>]
	//Pauli index is: 0 for I, 1 for X, 2 for y, 3 for Z
	//target index is the index of the target qubit of the rotation
	//Sequence of <control qubit indices> can be empty for uncontroled
	operation GradientClassicalSimulationAdapter(tolerance: Double, param : Double[], gates: Int[][], sample: Double[]) : (Double[])
	{

		return EstimateGradientFromClassicalSample(tolerance, param,unFlattenGateSequence(gates),sample,0);

	}

	/// # Summary
	/// Get a list of all the classification probabilities. In the from of (prob1,label) pairs. THIS operation is IN DEPRECATION
	///
	/// # Input
	/// ## samples
	/// a container of labeled samples
	///
	/// ## sched
	/// a schedule to define a subset of samples
	///
	/// ## param
	/// parameters of the circuits
	///
	/// ## gates
	/// the sequence of gates in the circuit
	///
	/// ## measCount
	/// the maximum number of quantum measurements used in the probability estimation
	/// IMPORTANT: measCount==0 implies deployment to simulator
	///
	/// # Output
	/// (no.hits, no.misses) pair
	///
	operation ClassificationProbabilitiesClassicalData(samples: LabeledSample[], sched: SamplingSchedule, param: Double[], gates: GateSequence, measCount: Int):
		(Double,Int)[]
	{
		mutable ret = [(0.0,0)];
		mutable sC = 0;
		for (rg in sched!)
		{
			for (ix in rg)
			{
				 set sC += 1;
			}
		}
		mutable N = qubitSpan(gates);
		if (Length(samples)>0)
		{
			let dL =Microsoft.Quantum.Math.Ceiling(Lg(IntAsDouble (Length(getData(Head(samples))))));
			if (N < dL)
			{
				set N = dL;
			}
		}
		set ret = new (Double,Int)[sC];
		mutable ir = 0;
		for (rg in sched!) {
			for (ix in rg) {
				let samp = samples[ix];
				//agnostic w.r.t. simulator (may still be simulable)
				let prob1 = CircuitResultClassical(1E-12,param, gates, getData(samp),measCount);
				set ret w/= ir <- (prob1, getLabel(samp));
				set ir += 1;
			}
		}

		return ret;
	}



	/// # Summary
	/// Get a list of all the classification probabilities. In the from of (prob1,label) pairs. THIS operation is IN DEPRECATION
	///
	/// # Input
	/// ## samples
	/// a container of labeled samples
	///
	/// ## sched
	/// a schedule to define a subset of samples
	///
	/// ## nQubits
	/// number of cubits in the classification circuit
	///
	/// ## gates
	/// the sequence of gates in the circuit
	///
	/// ## param
	/// parameters of the circuits
	///
	/// ## measCount
	///
	/// # Output
	/// array of corresponding estimated probabilities of the top class label
	///
	operation EstimateClassificationProbabilitiesClassicalData(
		tolerance : Double, samples : Double[][], sched : SamplingSchedule,
		nQubits : Int, gates : GateSequence, param : Double[],
		nMeasurements : Int
	) : Double[] {
		let effectiveTolerance = tolerance / IntAsDouble(Length(gates!));
		mutable ret = new Double[0];
		for (rg in sched!) {
			for (ix in rg) {
				let samp = samples[ix];
				let circEnc = NoisyInputEncoder(effectiveTolerance, samp);
				set ret += [QubitProbPhysical(circEnc, param, gates, nQubits, nMeasurements)];
			}
		}

		return ret;
	} //EstimateClassificationProbabilitiesClassicalData


	operation EstimateClassificationProbabilitiesClassicalDataAdapter(tolerance: Double, samples: Double[][], schedule: Int[][], nQubits: Int,  gates: Int[][], param: Double[], measCount: Int): Double[]
	{
		return EstimateClassificationProbabilitiesClassicalData(tolerance, samples, unFlattenSchedule(schedule), nQubits, unFlattenGateSequence(gates), param, measCount);
	}

	operation PrepareUniformSuperpositionLE(reg : LittleEndian) : Unit is Adj + Ctl {
        ApplyToEachCA(H, reg!);
	}

	/// # Summary
	/// Get a list of all the classification probabilities. In the from of (prob1,label) pairs.
	///
	/// # Input
	/// ## samples
	/// a container of labeled samples
	///
	/// ## sched
	/// a schedule to define a subset of samples
	///
	/// ## param
	/// parameters of the circuits
	///
	/// ## gates
	/// the sequence of gates in the circuit
	///
	/// ## measCount
	/// the maximum number of quantum measurements used in the probability estimation
	/// IMPORTANT: measCount==0 implies deployment to simulator
	///
	/// # Output
	/// List if triplets of the form (sample index, sample probaility, sample label)
	///
	operation ClassificationTripletsClassicalData(samples: LabeledSample[], sched: SamplingSchedule, param: Double[], gates: GateSequence, measCount: Int):
		(Int, Double, Int)[]
	{
		mutable ret = [(-1,0.0,0)];
		mutable sC = 0;
		for (rg in sched!)
		{
			for (ix in rg)
			{
				 set sC = sC +1;
			}
		}
		mutable N = qubitSpan(gates);
		if (not IsEmpty(samples)) {
			let dL =Microsoft.Quantum.Math.Ceiling(Lg(IntAsDouble (Length(getData(Head(samples))))));
			if (N < dL)
			{
				set N = dL;
			}
		}
		set ret = new (Int,Double,Int)[sC];
		mutable ir = 0;
		for (rg in sched!)
		{
			for (ix in rg)
			{
				let samp = samples[ix];
				let data = getData(samp);
				let circEnc = InputEncoder(data);
				let sg = StateGenerator((N,circEnc));
				let prob1 = CircuitResult(measCount, sg, param, gates);
				set ret w/=ir<-(ix,prob1,getLabel(samp));
				set ir = ir+1;
			}
		}

		return ret;
	}

	/// # Summary
	/// tallies hits and misses off a list of probability estimates
	///
	/// # Input
	/// ## pls
	/// a list of estimated probabilities with the corresponding class labels
	///
	/// ## bias
	/// bias on record
	///
	/// # Output
	/// (no.hits, no.misses) pair
	///
	function TallyHitsMisses(pls: (Double, Int)[], bias: Double) : (Int, Int) {
		mutable hits = 0;
		mutable misses = 0;
		for (pl in pls)
		{
			if (Fst(pl)+bias>0.5)
			{
				if (Snd(pl)<1)
				{
					//Misclassification
					set misses=misses+1;
				}
				else
				{
					set hits=hits+1;
				}
			}
			else
			{
				if (Snd(pl)>0)
				{
					//Misclassification
					set misses=misses+1;
				}
				else
				{
					set hits=hits+1;
				}
			}
		}
		return (hits,misses);
	}

	/// # Summary
	/// generate a flat list of sample indices where mispredictions occur
	///
	/// # Input
	/// ## sched
	/// a sampling schedule
	///
	/// ## pls
	/// a list of estimated probabilities with the corresponding class labels
	///
	/// ## bias
	/// bias on record
	///
	/// # Output
	/// the list of indices where mispredictions occur
	///
	function MissLocations(sched : SamplingSchedule, pls : (Double, Int)[], bias: Double) : Int[] {
		mutable ret = new Int[0];
		mutable ir = 0;

		for (rg in sched!) {
			for (ix in rg) {
				let (prob1, lab) = pls[ir];
				set ir += 1;
				if (prob1 + bias > 0.5) {
					if (lab < 1) {
						set ret += [ix];
					}
				} else {
					if (lab > 0) {
						set ret += [ix];
					}
				}
			}
		}
		return ret;
	}

	/// # Summary
	/// C#-friendly adapter to misclassification tally
	///
	/// # Input
	/// ## vectors
	/// data vectors in flat encoding
	///
	/// ## labels
	/// array of corresponding class lables
	///
	/// ## schedule
	/// flat representation of index subset on which the circuit is scored
	///
	/// ## param
	/// circuit parameters
	///
	/// ## gateStructure
	/// gate structure in flat representation
	///
	/// ## bias
	/// prediction bias to be tested
	///
	/// ## measCount
	/// maximum number of quantum measurements per estimation (measCount==0 implies simulator deployment)
	///
	/// # Output
	/// the number of misclassifications
	///
	operation MisclassificationScoreAdapter(vectors: Double[][], labels: Int[], schedule: Int[][], param: Double[], gateStructure: Int[][], bias: Double, measCount: Int) : Int {
		mutable misses = 0;
		let samples = unFlattenLabeledSamples(vectors,labels);
		let gates = unFlattenGateSequence(gateStructure);
		let sched = unFlattenSchedule(schedule);

		let pls = ClassificationProbabilitiesClassicalData(samples,sched,param,gates,measCount);
		let biasCurrent = adjustBias(pls, bias, 0.01, 10);
		let (h1,m1) = TallyHitsMisses(pls,biasCurrent);
		return m1;
	}


	/// # Summary
	/// C#-friendly adapter to misclassification tally
	///
	/// # Input
	/// ## vectors
	/// data vectors in flat encoding
	///
	/// ## labels
	/// array of corresponding class lables
	///
	/// ## schedule
	/// flat representation of index subset on which the circuit is scored
	///
	/// ## param
	/// circuit parameters
	///
	/// ## gateStructure
	/// gate structure in flat representation
	///
	/// ## bias
	/// prediction bias to be tested
	///
	/// ## measCount
	/// maximum number of quantum measurements per estimation (measCount==0 implies simulator deployment)
	///
	/// # Output
	/// schedule of indices of misclassified samples
	///
	operation MisclassificationsAsScheduleAdapter(vectors: Double[][], labels: Int[], schedule: Int[][], param: Double[], gateStructure: Int[][], bias: Double, measCount: Int) : Int[][]
	{
		mutable misses = new Int[][0];
		let samples = unFlattenLabeledSamples(vectors,labels);
		let gates = unFlattenGateSequence(gateStructure);
		let sched = unFlattenSchedule(schedule);

		let pls = ClassificationTripletsClassicalData(samples,sched,param,gates,measCount);
		mutable tmp = new (Double,Int)[Length(pls)];
		for (it in 0..(Length(tmp)-1))
		{
			let (a,b,c) = pls[it];
			set tmp w/=it<-(b,c);
		}
		let biasCurrent = adjustBias(tmp, bias, 0.01, 10);
		for (pl in pls)
		{
			let (ix,pp,lb) = pl;
			if (pp+biasCurrent>0.5)
			{
				if (lb <1)
				{
					//Misclassification
					set misses=misses + [[ix,1,ix]];
				}
			}
			else
			{
				if (lb>0)
				{
					//Misclassification
					set misses=misses + [[ix,1,ix]];
				}
			}
		}
		return misses;
	}


		/// # Summary
	/// C#-friendly adapter to misclassification tally
	///
	/// # Input
	/// ## vectors
	/// data vectors in flat encoding
	///
	/// ## labels
	/// array of corresponding class lables
	///
	/// ## schedule
	/// flat representation of index subset on which the circuit is scored
	///
	/// ## param
	/// circuit parameters
	///
	/// ## gateStructure
	/// gate structure in flat representation
	///
	/// ## bias
	/// prediction bias to be tested
	///
	/// ## measCount
	/// maximum number of quantum measurements per estimation (measCount==0 implies simulator deployment)
	///
	/// # Output
	/// schedule of indices of misclassified samples
	///
	operation TestMisclassificationsAsScheduleAdapter(vectors: Double[][], labels: Int[], schedule: Int[][], param: Double[], gateStructure: Int[][], bias: Double, measCount: Int) : Int[][]
	{
		mutable misses = new Int[][0];
		let samples = unFlattenLabeledSamples(vectors,labels);
		let gates = unFlattenGateSequence(gateStructure);
		let sched = unFlattenSchedule(schedule);

		let pls = ClassificationTripletsClassicalData(samples,sched,param,gates,measCount);
		mutable tmp = new (Double,Int)[Length(pls)];
		for (it in 0..(Length(tmp)-1))
		{
			let (a,b,c) = pls[it];
			set tmp w/=it<-(b,c);
		}
		let biasCurrent = bias;
		for (pl in pls)
		{
			let (ix,pp,lb) = pl;
			if (pp+biasCurrent>0.5)
			{
				if (lb <1)
				{
					//Misclassification
					set misses=misses + [[ix,1,ix]];
				}
			}
			else
			{
				if (lb>0)
				{
					//Misclassification
					set misses=misses + [[ix,1,ix]];
				}
			}
		}
		return misses;
	}



	/// # Summary
	/// C#-friendly adapter to misclassification tally
	///
	/// # Input
	/// ## vectors
	/// data vectors in flat encoding
	///
	/// ## labels
	/// array of corresponding class lables
	///
	/// ## schedule
	/// flat representation of index subset on which the circuit is scored
	///
	/// ## param
	/// circuit parameters
	///
	/// ## gateStructure
	/// gate structure in flat representation
	///
	/// ## bias
	/// prediction bias to be tested
	///
	/// ## measCount
	/// maximum number of quantum measurements per estimation (measCount==0 implies simulator deployment)
	///
	/// # Output
	/// (bias, schedule of indices of misclassified samples)
	///
	operation BiasAndMisclassificationsAsScheduleAdapter(vectors: Double[][], labels: Int[], schedule: Int[][], param: Double[], gateStructure: Int[][], bias: Double, measCount: Int) : (Double,Int[][])
	{
		mutable misses = new Int[][0];
		let samples = unFlattenLabeledSamples(vectors,labels);
		let gates = unFlattenGateSequence(gateStructure);
		let sched = unFlattenSchedule(schedule);

		let pls = ClassificationTripletsClassicalData(samples,sched,param,gates,measCount);
		mutable tmp = new (Double,Int)[Length(pls)];
		for (it in 0..(Length(tmp)-1))
		{
			let (a,b,c) = pls[it];
			set tmp w/=it<-(b,c);
		}
		let biasCurrent = adjustBias(tmp, bias, 0.01, 10);
		for (pl in pls)
		{
			let (ix,pp,lb) = pl;
			if (pp+biasCurrent>0.5)
			{
				if (lb <1)
				{
					//Misclassification
					set misses=misses + [[ix,1,ix]];
				}
			}
			else
			{
				if (lb>0)
				{
					//Misclassification
					set misses=misses + [[ix,1,ix]];
				}
			}
		}
		return (biasCurrent, misses);
	}


	/// # Summary
	/// Semi-greedily find a bias value that leads to near-minimum misclassification score
	///
	operation recomputeBias(probabilities: Double[], labels: Int[], sched: SamplingSchedule, bias: Double, tolerance: Double, maxIter: Int) : Double
	{
		mutable min1 = 1.0;
		mutable max0 = 0.0;
		mutable ipro = 0;
		for (rg in sched!)
		{
			for(ix in rg)
			{
				let prob = probabilities[ipro];
				let lab = labels[ix];
				if (lab > 0)
				{
					if (min1 > prob)
					{
						set min1 = prob;
					}
				}
				else
				{
					if  (max0 < prob)
					{
						set max0 = prob;
					}
				}
				set ipro = ipro +1 ;
			}
		} //rof
		if (max0 <= min1)
		{
			return 0.5*(1.0-max0-min1); //Gives a perfect classification
		}
		mutable mBest = Length(probabilities);
		mutable bBest = bias;
		mutable bLeft = 0.5-max0;
		mutable bRight = 0.5-min1;
		mutable bestDir = 0;
		mutable proposedLabels = InferredLabels(probabilities,bLeft);
		mutable mLeft = NMismatches(proposedLabels, labels, sched);
		if (mLeft < mBest)
		{
			set bBest = bLeft;
			set mBest = mLeft;
			set bestDir = -1;
		}
		set proposedLabels = InferredLabels(probabilities,bRight);
		mutable mRight = NMismatches(proposedLabels, labels, sched);
		if (mRight < mBest)
		{
			set bBest = bRight;
			set mBest = mRight;
			set bestDir = 1;
		}

		for (iter in 1..maxIter)
		{
			if ((bRight - bLeft) < tolerance)
			{
				return bBest;
			}
			let bMiddle = 0.5*(bLeft+bRight);
			set proposedLabels = InferredLabels(probabilities,bMiddle);
			let mMiddle = NMismatches(proposedLabels, labels, sched);

			if (mMiddle < mLeft)
			{
				if (bestDir > 0) //replace the weaker end
				{
					set bLeft = bMiddle;
					set mLeft = mMiddle;

					if (mMiddle < mBest)
					{
						set bBest = bMiddle;
						set mBest = mMiddle;
						set bestDir = -1; //note that the left end is now better
					}
				}
				else //right end was the weaker end
				{
						set bRight = bMiddle;
						set mRight = mMiddle;
						if (mMiddle < mBest)
						{
							set bBest = bMiddle;
							set mBest = mMiddle;
							set bestDir = 1; //note that the right end is now better
						}
				}
				//Done with the left end
			}
			else
			{

				if (mMiddle < mRight)
				{
					//We are better than the right but worse than the left
					//Hence the right must be weaker
						set bRight = bMiddle;
						set mRight = mMiddle;
				}
				else
				{
					return bBest; //cannot continue the greedy search
				}
			}

		}
		return bias;
	} //recomputeBias

	/// # Summary
	/// Semi-greedily find a bias value that leads to near-minimum misclassification score
	///
	/// # Input
	/// ## pls
	/// a plist of probability estimates and corresponding labels
	///
	/// ## bias
	/// a fallback value of bias
	///
	/// ## tol
	/// acceptable tolerance in the bias estimate
	///
	/// ## maxIter
	/// maximum number of trial bisections
	///
	/// # Output
	/// the bias estimate
	///
	function adjustBias(pls: (Double,Int)[], bias: Double, tol:Double, maxIter: Int) : Double
	{
		mutable min1 = 1.0;
		mutable max0 = 0.0;
		for (pl in pls)
		{
			if (Snd(pl)>0)
			{
				if (min1 > Fst(pl))
				{
					set min1 = Fst(pl);
				}
			}
			else
			{
				if  (max0 < Fst(pl))
				{
					set max0 = Fst(pl);
				}
			}
		}
		if (max0 <= min1)
		{
			return 0.5*(1.0-max0-min1); //Gives a perfect classification
		}
		mutable hBest = 0;
		mutable mBest = Length(pls);
		mutable bBest = bias;
		mutable bLeft = 0.5-max0;
		mutable bRight = 0.5-min1;
		mutable bestDir = 0;
		mutable (hLeft,mLeft) = TallyHitsMisses(pls,bLeft);
		if (mLeft < mBest)
		{
			set bBest = bLeft;
			set hBest = hLeft;
			set mBest = mLeft;
			set bestDir = -1;
		}
		mutable (hRight, mRight) = TallyHitsMisses(pls,bRight);

		if (mRight < mBest)
		{
			set bBest = bRight;
			set hBest = hRight;
			set mBest = mRight;
			set bestDir = 1;
		}
		for (iter in 1..maxIter)
		{
			if ((bRight - bLeft)<tol)
			{
				return bBest;
			}
			let bMiddle = 0.5*(bLeft+bRight);
			let (hMiddle,mMiddle) = TallyHitsMisses(pls,bMiddle);

			if (mMiddle < mLeft)
			{
				if (bestDir > 0) //replace the weaker end
				{
					set bLeft = bMiddle;
					set hLeft = hMiddle;
					set mLeft = mMiddle;

					if (mMiddle * hBest < hMiddle * mBest)
					{
						set bBest = bMiddle;
						set hBest = hMiddle;
						set mBest = mMiddle;
						set bestDir = -1; //note that the left end is now better
					}
				}
				else //right end was the weaker end
				{
						set bRight = bMiddle;
						set hRight = hMiddle;
						set mRight = mMiddle;
						if (mMiddle * hBest < hMiddle * mBest)
						{
							set bBest = bMiddle;
							set hBest = hMiddle;
							set mBest = mMiddle;
							set bestDir = 1; //note that the right end is now better
						}
				}
				//Done with the left end
			}
			else
			{
				if (mMiddle < mRight)
				{
					//We are better than the right but worse than the left
					//Hence the right must be weaker
						set bRight = bMiddle;
						set hRight = hMiddle;
						set mRight = mMiddle;
				}
				else
				{
					return bBest; //cannot continue the greedy search
				}
			}
		} //rof iter
		return bBest;
	} //adjust bias

	/// # Summary
	/// Extract a mini batch of samples and wrap the batch as a LabeledSampleContainer
	///
	/// # Input
	/// ## size
	/// desired number of samples in the mini batch
	///
	/// ## ixLoc
	/// starting index for the batch in the list of locations
	///
	/// ## locations
	/// list of indices of samples of interest
	///
	/// ## samples
	/// the container to extract the samples from
	///
	/// # Output
	/// the mini batched wrapped as a LabeledSampleContainer
	///
	/// # Remarks
	/// the resulting mini batch can be occasionally shorter than the requested 'size'
	/// (when it falls on the tail end of the list of 'locations')
	///
	function ExtractMiniBatch(size: Int, ixLoc: Int, locations: Int[], samples: LabeledSample[]): LabeledSample[] {
		mutable cnt = Length(locations)-ixLoc;
		if (cnt > size)
		{
			set cnt = size;
		}
		mutable rgSamples = new LabeledSample[0];
		if (cnt > 0)
		{
			set rgSamples = new LabeledSample[cnt];
			for (isa in 0..(cnt-1))
			{
				set rgSamples w/=isa<- samples[locations[ixLoc+isa]];
			}
		}
		return rgSamples;
	}

	/// # Summary
	/// (Randomly) inflate of deflate the source number
	operation randomize(src : Double, relativeFuzz : Double) : Double {
        return src * (
            1.0 + relativeFuzz * (Random([0.5, 0.5]) > 0 ? 1.0 | -1.0)
        );
	}



	/// Summary
	/// One possible C#-friendly wrap around the StochasticTrainingLoop
	///
	operation StochasticTrainingLoopPlainAdapter(vectors: Double[][], labels: Int[], sched: Int[][], schedScore: Int[][], periodScore: Int,
			 miniBatchSize: Int, param: Double[],gates: Int[][], bias: Double, lrate: Double, maxEpochs: Int, tol: Double, measCount: Int ) : Double[] //
	{
		let samples = unFlattenLabeledSamples(vectors,labels);
		let sch = unFlattenSchedule(sched);
		let schScore = unFlattenSchedule(sched);
		let gts = unFlattenGateSequence(gates);
		let ((h,m),(b,parpar)) = StochasticTrainingLoop(samples, sch, schScore, periodScore,
			 miniBatchSize, param, gts, bias, lrate, maxEpochs, tol, measCount);
		mutable ret = new Double[Length(parpar)+3];
		set ret w/=0<-IntAsDouble (h);
		set ret w/=1<-IntAsDouble (m);
		set ret w/=2<-b;
		for (j in 0..(Length(parpar)-1))
		{
			set ret w/=(j+3)<-parpar[j];
		}
		return ret;
	}

	function InferredLabels(probabilities: Double[], bias: Double): Int[] {
		mutable ret = new Int[Length(probabilities)];
		for (il in 0..(Length(probabilities) - 1)) {
			set ret w/= il <- probabilities[il] + bias > 0.5 ? 1 | 0;
		}
		return ret;
	}

}