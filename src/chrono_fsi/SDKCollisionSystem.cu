#include "custom_cutil_math.h"
#include "SPHCudaUtils.h"
#include "SDKCollisionSystem.cuh"

//#include "extraOptionalFunctions.cuh"

//#include "SDKCollisionSystemAdditional.cuh"

__constant__ real_ dTD_SDK;
__constant__ int2 updatePortionD;
__constant__ real_ dTD;


//--------------------------------------------------------------------------------------------------------------------------------
// calculate position in uniform grid
__device__ int3 calcGridPos(real3 p) {
	int3 gridPos;
	gridPos.x = floor((p.x - paramsD.worldOrigin.x) / paramsD.cellSize.x);
	gridPos.y = floor((p.y - paramsD.worldOrigin.y) / paramsD.cellSize.y);
	gridPos.z = floor((p.z - paramsD.worldOrigin.z) / paramsD.cellSize.z);
	return gridPos;
}
//--------------------------------------------------------------------------------------------------------------------------------
// calculate address in grid from position (clamping to edges)
__device__ uint calcGridHash(int3 gridPos) {

	gridPos.x -= ((gridPos.x >= paramsD.gridSize.x) ? paramsD.gridSize.x : 0);
	gridPos.y -= ((gridPos.y >= paramsD.gridSize.y) ? paramsD.gridSize.y : 0);
	gridPos.z -= ((gridPos.z >= paramsD.gridSize.z) ? paramsD.gridSize.z : 0);

	gridPos.x += ((gridPos.x < 0) ? paramsD.gridSize.x : 0);
	gridPos.y += ((gridPos.y < 0) ? paramsD.gridSize.y : 0);
	gridPos.z += ((gridPos.z < 0) ? paramsD.gridSize.z : 0);

	return __umul24(__umul24(gridPos.z, paramsD.gridSize.y), paramsD.gridSize.x) + __umul24(gridPos.y, paramsD.gridSize.x) + gridPos.x;
}
//--------------------------------------------------------------------------------------------------------------------------------
//computes dV/dt and dRho/dt, i.e. force terms. First
__device__ inline real4 DifVelocityRho(
		const real3 & dist3,
		const real_ & d,
		const real4 & velMasA,
		const real3 & vel_XSPH_A,
		const real4 & velMasB,
		const real3 & vel_XSPH_B,
		const real4 & rhoPresMuA,
		const real4 & rhoPresMuB,
		real_ multViscosity) {


	real_ epsilonMutualDistance = .01f;
	real3 gradW = GradW(dist3);

	//real_ vAB_Dot_rAB = dot(R3(velMasA - velMasB), dist3);

//	//*** Artificial viscosity type 1.1
//	real_ alpha = .001;
//	real_ c_ab = 10 * paramsD.v_Max; //Ma = .1;//sqrt(7.0f * 10000 / ((rhoPresMuA.x + rhoPresMuB.x) / 2.0f));
//	//real_ h = paramsD.HSML;
//	real_ rho = .5f * (rhoPresMuA.x + rhoPresMuB.x);
//	real_ nu = alpha * paramsD.HSML * c_ab / rho;

//	//*** Artificial viscosity type 1.2
//	real_ nu = 22.8f * paramsD.mu0 / 2.0f / (rhoPresMuA.x * rhoPresMuB.x);
//	real3 derivV = -velMasB.w * (
//		rhoPresMuA.y / (rhoPresMuA.x * rhoPresMuA.x) + rhoPresMuB.y / (rhoPresMuB.x * rhoPresMuB.x)
//		- nu * vAB_Dot_rAB / ( d * d + epsilonMutualDistance * paramsD.HSML * paramsD.HSML )
//		) * gradW;
//	return R4(derivV,
//		rhoPresMuA.x * velMasB.w / rhoPresMuB.x * dot(vel_XSPH_A - vel_XSPH_B, gradW));

	//*** Artificial viscosity type 2
	real_ rAB_Dot_GradW = dot(dist3, gradW);
	real_ rAB_Dot_GradW_OverDist = rAB_Dot_GradW / (d * d + epsilonMutualDistance * paramsD.HSML * paramsD.HSML);
	real3 derivV = -velMasB.w * (rhoPresMuA.y / (rhoPresMuA.x * rhoPresMuA.x) + rhoPresMuB.y / (rhoPresMuB.x * rhoPresMuB.x)) * gradW
			+ velMasB.w * (8.0f * multViscosity) * paramsD.mu0 * pow(rhoPresMuA.x + rhoPresMuB.x, -2) * rAB_Dot_GradW_OverDist
					* R3(velMasA - velMasB);
	real_ zeta = 0;//.05;//.1;
	real_ derivRho = rhoPresMuA.x * velMasB.w / rhoPresMuB.x * dot(vel_XSPH_A - vel_XSPH_B, gradW);
//	real_ zeta = 0;//.05;//.1;
//	real_ derivRho = rhoPresMuA.x * velMasB.w * invrhoPresMuBx * (dot(vel_XSPH_A - vel_XSPH_B, gradW)
//			+ zeta * paramsD.HSML * (10 * paramsD.v_Max) * 2 * (rhoPresMuB.x / rhoPresMuA.x - 1) * rAB_Dot_GradW_OverDist
//			);
	return R4(derivV, derivRho);

//	//*** Artificial viscosity type 1.3
//	real_ rAB_Dot_GradW = dot(dist3, gradW);
//	real3 derivV = -velMasB.w * (rhoPresMuA.y / (rhoPresMuA.x * rhoPresMuA.x) + rhoPresMuB.y / (rhoPresMuB.x * rhoPresMuB.x)) * gradW
//		+ velMasB.w / (rhoPresMuA.x * rhoPresMuB.x) * 2.0f * paramsD.mu0 * rAB_Dot_GradW / ( d * d + epsilonMutualDistance * paramsD.HSML * paramsD.HSML ) * R3(velMasA - velMasB);
//	return R4(derivV,
//		rhoPresMuA.x * velMasB.w / rhoPresMuB.x * dot(vel_XSPH_A - vel_XSPH_B, gradW));
}
//--------------------------------------------------------------------------------------------------------------------------------
__device__ inline real3 DifVelocity_SSI_DEM(
				const real3 & dist3,
				const real_ & d,
				const real4 & velMasA,
				const real4 & velMasB) {
//printf("** DifVelocity_SSI_DEM\n");
	real_ l = paramsD.MULT_INITSPACE * paramsD.HSML - d; //penetration distance
	if (l < 0) {
		return R3(0);
	}
	real_ kS =  .00006;//6;//3; //50; //1000.0; //392400.0;	//spring. 50 worked almost fine. I am using 30 to be sure!
	real_ kD = 40;//20;//40.0;//20.0; //420.0;				//damping coef. // 40 is good don't change it.
	real3 n = dist3 / d; //unit vector B to A
	real_ m_eff = (velMasA.w * velMasB.w) / (velMasA.w + velMasB.w);
	real3 force = (/*pow(paramsD.sizeScale, 3) * */kS * l - kD * m_eff * dot(R3(velMasA - velMasB), n)) * n; //relative velocity at contact is simply assumed as the relative vel of the centers. If you are updating the rotation, this should be modified.
	return force / velMasA.w; //return dV/dT same as SPH
}
//--------------------------------------------------------------------------------------------------------------------------------
__device__ inline real3 DifVelocity_SSI_Lubrication(
				const real3 & dist3,
				const real_ & d,
				const real4 & velMasA,
				const real4 & velMasB) {
//printf("** DifVelocity_SSI_Lubrication\n");
	real_ Delta_c = paramsD.HSML;
	real_ s = d - paramsD.MULT_INITSPACE * paramsD.HSML;
	if (s > Delta_c) return R3(0);

	real_ Delta_i = .1 * Delta_c;
	real_ mult=0;
	if (s > Delta_i) {
		mult = 1/s - 1/Delta_c;
	} else {
		mult = 1/Delta_i - 1/Delta_c;
	}
	real3 n = dist3 / d; //unit vector B to A
	real3 force = -(mult * 1.5 * PI * paramsD.mu0 * paramsD.HSML * paramsD.HSML) * dot(R3(velMasA - velMasB), n) * n;
	return force / velMasA.w;
}
//--------------------------------------------------------------------------------------------------------------------------------
// collide a particle against all other particles in a given cell
__device__
real3 deltaVShare(
		int3 gridPos,
		uint index,
		real3 posRadA,
		real4 velMasA,
		real4 rhoPresMuA,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real4* sortedRhoPreMu,
		uint* cellStart,
		uint* cellEnd) {

	uint gridHash = calcGridHash(gridPos);
	// get start of bucket for this cell
	real3 deltaV = R3(0.0f);

	uint startIndex = FETCH(cellStart, gridHash);
	if (startIndex != 0xffffffff) { // cell is not empty
		// iterate over particles in this cell
		uint endIndex = FETCH(cellEnd, gridHash);

		for (uint j = startIndex; j < endIndex; j++) {
			if (j != index) { // check not colliding with self
				real3 posRadB = FETCH(sortedPosRad, j);
				real3 dist3 = Distance(posRadA, posRadB);
				real_ d = length(dist3);
				if (d > RESOLUTION_LENGTH_MULT * paramsD.HSML) continue;
				real4 rhoPresMuB = FETCH(sortedRhoPreMu, j);
				if (!( rhoPresMuA.w <0 && rhoPresMuB.w < 0 )) continue;//# A and B must be fluid, accoring to colagrossi (2003), the other phase (i.e. rigid) should not be considered)
				real_ multRho = 2.0f / (rhoPresMuA.x + rhoPresMuB.x);
				real4 velMasB = FETCH(sortedVelMas, j);
				deltaV += velMasB.w * R3(velMasB - velMasA) * W3(d) * multRho;
			}
		}
	}
	return deltaV;
}
//--------------------------------------------------------------------------------------------------------------------------------
// modify pressure for body force
__device__ __inline__
void modifyPressure(real4 & rhoPresMuB, const real3 & dist3Alpha) {
	//body force in x direction
	rhoPresMuB.y = (dist3Alpha.x > 0.5 * paramsD.boxDims.x) ? (rhoPresMuB.y - paramsD.deltaPress.x) : rhoPresMuB.y;
	rhoPresMuB.y = (dist3Alpha.x < -0.5 * paramsD.boxDims.x) ? (rhoPresMuB.y + paramsD.deltaPress.x) : rhoPresMuB.y;
	//body force in x direction
	rhoPresMuB.y = (dist3Alpha.y > 0.5 * paramsD.boxDims.y) ? (rhoPresMuB.y - paramsD.deltaPress.y) : rhoPresMuB.y;
	rhoPresMuB.y = (dist3Alpha.y < -0.5 * paramsD.boxDims.y) ? (rhoPresMuB.y + paramsD.deltaPress.y) : rhoPresMuB.y;
	//body force in x direction
	rhoPresMuB.y = (dist3Alpha.z > 0.5 * paramsD.boxDims.z) ? (rhoPresMuB.y - paramsD.deltaPress.z) : rhoPresMuB.y;
	rhoPresMuB.y = (dist3Alpha.z < -0.5 * paramsD.boxDims.z) ? (rhoPresMuB.y + paramsD.deltaPress.z) : rhoPresMuB.y;
}
//--------------------------------------------------------------------------------------------------------------------------------
// collide a particle against all other particles in a given cell
__device__
real4 collideCell(
		int3 gridPos,
		uint index,
		real3 posRadA,
		real4 velMasA,
		real3 vel_XSPH_A,
		real4 rhoPresMuA,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real3* vel_XSPH_Sorted_D,
		real4* sortedRhoPreMu,

		real3* posRigidD,
		int* rigidIdentifierD,

		uint* cellStart,
		uint* cellEnd,
		uint* gridMarkerIndex) {

	uint gridHash = calcGridHash(gridPos);
	// get start of bucket for this cell
	real3 derivV = R3(0.0f);
	real_ derivRho = 0.0f;

	uint startIndex = FETCH(cellStart, gridHash);
	if (startIndex != 0xffffffff) { // cell is not empty
		// iterate over particles in this cell
		uint endIndex = FETCH(cellEnd, gridHash);

		for (uint j = startIndex; j < endIndex; j++) {
			if (j != index) { // check not colliding with self
				real3 posRadB = FETCH(sortedPosRad, j);
				real3 dist3Alpha = posRadA - posRadB;
				real3 dist3 = Distance(posRadA, posRadB);
				real_ d = length(dist3);
				if (d > RESOLUTION_LENGTH_MULT * paramsD.HSML) continue;

				real4 velMasB = FETCH(sortedVelMas, j);
				real4 rhoPresMuB = FETCH(sortedRhoPreMu, j);

				modifyPressure(rhoPresMuB, dist3Alpha);

				if (rhoPresMuA.w < 0  ||  rhoPresMuB.w < 0) {
					if (rhoPresMuA.w == 0) continue;
					real_ multViscosit = 1.0f;

//					if ( rhoPresMuB.w == 0) { //**one of them is boundary, the other one is fluid
					if ( rhoPresMuA.w >= 0 ) { //**one of them is boundary, the other one is fluid
						multViscosit = paramsD.multViscosity_FSI;
						rhoPresMuA.y = rhoPresMuB.y;
					}
					if ( rhoPresMuB.w >= 0) { //**one of them is boundary, the other one is fluid
						multViscosit = paramsD.multViscosity_FSI;
						rhoPresMuB.y = rhoPresMuA.y;
					}
					//*** modify the pressure at the periodic boundary
//					if (length(posRadA - posRadB) > (RESOLUTION_LENGTH_MULT + 1) * paramsD.HSML) { //i.e. at periodic BC. project pressure up the periodic boundary
//						rhoPresMuB.x = rhoPresMuA.x;
//						rhoPresMuB.y = rhoPresMuA.y;
//					}
					//*** end modify the pressure at the boundary
//					else { //**One of them is fluid, the other one is fluid/solid (boundary was considered previously)
//						multViscosit = 1.0f;
//					}
					real4 derivVelRho = R4(0.0f);
					real3 vel_XSPH_B = FETCH(vel_XSPH_Sorted_D, j);
					derivVelRho = DifVelocityRho(dist3, d, velMasA, vel_XSPH_A, velMasB, vel_XSPH_B, rhoPresMuA, rhoPresMuB, multViscosit);
					derivV += R3(derivVelRho);
					derivRho += derivVelRho.w;
				}
				else if (fabs(rhoPresMuA.w - rhoPresMuB.w) > 0) { //implies: one of them is solid/boundary, ther other one is solid/boundary of different type or different solid
////					real3 dV = DifVelocity_SSI_DEM(dist3, d, velMasA, velMasB);
//					real3 dV = DifVelocity_SSI_Lubrication(dist3, d, velMasA, velMasB);
//
//					if (rhoPresMuA.w > 0 && rhoPresMuA.w <= numObjectsD.numRigidBodies) { //i.e. rigid
//						uint originalIndex = gridMarkerIndex[index];
//						uint BCE_Index = originalIndex - numObjectsD.startRigidMarkers;
//						real3 s3 = Distance(posRadA, posRigidD[rigidIdentifierD[BCE_Index]]);  //assume convex.
//						derivV += (dot(dV, s3) > 0) ? (-dV) : (dV); //fancy check: if a go within b, dV becomes attractive force, so it should change sign to become repulsive.
//					} else { // flex or boundary. boundary is not important. but flex is not supported yet
//						derivV += dV; //flex doesn't support fancy check as rigid
//					}
				}
			}
		}
	}

	// ff1
//	if (rhoPresMuA.w > 0) printf("force value %f %f %f\n", 1e20*derivV.x, 1e20*derivV.y, 1e20*derivV.z);
	return R4(derivV, derivRho);
}//--------------------------------------------------------------------------------------------------------------------------------
// collide a particle against all other particles in a given cell
__device__ __inline__
void stressCell(
		real3 & devS3,
		real3 & volS3,
		int3 gridPos,
		uint index,
		real3 posRadA,
		real4 velMasA,
		real4 rhoPresMuA,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real4* sortedRhoPreMu,

		uint* cellStart,
		uint* cellEnd) {

	uint gridHash = calcGridHash(gridPos);
	// get start of bucket for this cell
	real3 derivV = R3(0.0f);
	real_ derivRho = 0.0f;

	uint startIndex = FETCH(cellStart, gridHash);
	if (startIndex != 0xffffffff) { // cell is not empty
		// iterate over particles in this cell
		uint endIndex = FETCH(cellEnd, gridHash);

		for (uint j = startIndex; j < endIndex; j++) {
			if (j != index) { // check not colliding with self
				real3 posRadB = FETCH(sortedPosRad, j);
				real3 dist3Alpha = posRadA - posRadB;
				real3 dist3 = Distance(posRadA, posRadB);
				real_ d = length(dist3);
				if (d > RESOLUTION_LENGTH_MULT * paramsD.HSML) continue;

				real4 velMasB = FETCH(sortedVelMas, j);
				real4 rhoPresMuB = FETCH(sortedRhoPreMu, j);

				real3 vr = R3(velMasB - velMasA);
				real3 gradW = GradW(dist3);

				// Randles and Libersky, 1996
				devS3 += -paramsD.mu0 * velMasB.w / rhoPresMuB.x *
						R3(vr.x * gradW.y + vr.y * gradW.x, vr.x * gradW.z + vr.z * gradW.x, vr.y * gradW.z + vr.z * gradW.y);
				volS3 += -paramsD.mu0 * velMasB.w / rhoPresMuB.x * 4.0 / 3.0 *
						R3(vr.x * gradW.x, vr.y * gradW.y, vr.z * gradW.z);
			}
		}
	}
}
//--------------------------------------------------------------------------------------------------------------------------------
// collide a particle against all other particles in a given cell
__device__
void collideCellDensityReInit(
		real_ & densityShare,
		real_ & denominator,
		int3 gridPos,
		uint index,
		real3 posRadA,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real4* sortedRhoPreMu,
		uint* cellStart,
		uint* cellEnd) {

	//?c2 printf("grid pos %d %d %d \n", gridPos.x, gridPos.y, gridPos.z);
	uint gridHash = calcGridHash(gridPos);
	// get start of bucket for this cell
	real_ densityShare2 = 0.0f;
	real_ denominator2 = 0.0f;

	uint startIndex = FETCH(cellStart, gridHash);
	if (startIndex != 0xffffffff) { // cell is not empty
		// iterate over particles in this cell
		uint endIndex = FETCH(cellEnd, gridHash);

		for (uint j = startIndex; j < endIndex; j++) {
			if (j != index) { // check not colliding with self
				real3 posRadB = FETCH(sortedPosRad, j);
				real4 velMasB = FETCH(sortedVelMas, j);
				real4 rhoPreMuB = FETCH(sortedRhoPreMu, j);
				real3 dist3 = Distance(posRadA, posRadB);
				real_ d = length(dist3);
				if (d > RESOLUTION_LENGTH_MULT * paramsD.HSML) continue;
				real_ partialDensity = velMasB.w * W3(d); //optimize it ?$
				densityShare2 += partialDensity;
				denominator2 += partialDensity / rhoPreMuB.x;
				//if (fabs(W3(d)) < .00000001) {printf("good evening, distance %f %f %f\n", dist3.x, dist3.y, dist3.z);
				//printf("posRadA %f %f %f, posRadB, %f %f %f\n", posRadA.x, posRadA.y, posRadA.z, posRadB.x, posRadB.y, posRadB.z);
				//}
			}
		}
	}
	densityShare += densityShare2;
	denominator += denominator2;
}
//--------------------------------------------------------------------------------------------------------------------------------
// collide a particle against all other particles in a given cell
__device__
void projectTheClosestFluidMarker(
		real3 & distRhoPress,
		int3 gridPos,
		uint index,
		real3 posRadA,
		real3* sortedPosRad,
		real4* sortedRhoPreMu,
		uint* cellStart,
		uint* cellEnd) {

	//?c2 printf("grid pos %d %d %d \n", gridPos.x, gridPos.y, gridPos.z);
	uint gridHash = calcGridHash(gridPos);
	// get start of bucket for this cell
	uint startIndex = FETCH(cellStart, gridHash);
	if (startIndex != 0xffffffff) { // cell is not empty
		// iterate over particles in this cell
		uint endIndex = FETCH(cellEnd, gridHash);

		for (uint j = startIndex; j < endIndex; j++) {
			if (j == index) continue;
			real4 rhoPreMuB = FETCH(sortedRhoPreMu, j);
			if (rhoPreMuB.w > -.1) continue; //we don't care about the closest non-fluid marker
			real3 posRadB = FETCH(sortedPosRad, j);
			real3 dist3 = Distance(posRadA, posRadB);
			real_ d = length(dist3);
			if (distRhoPress.x > d) {
				distRhoPress = R3(d, rhoPreMuB.x, rhoPreMuB.y);
			}
		}
	}
}
//--------------------------------------------------------------------------------------------------------------------------------
// collide a particle against all other particles in a given cell
__device__
void calcOnCartesianShare(
		real3 & v_share,
		real4 & rp_share,
		int3 gridPos,
		real4 gridNodePos4,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real4* sortedRhoPreMu,
		uint* cellStart,
		uint* cellEnd) {

	//?c2 printf("grid pos %d %d %d \n", gridPos.x, gridPos.y, gridPos.z);
	uint gridHash = calcGridHash(gridPos);
	// get start of bucket for this cell
	uint startIndex = FETCH(cellStart, gridHash);
	if (startIndex != 0xffffffff) { // cell is not empty
		// iterate over particles in this cell
		uint endIndex = FETCH(cellEnd, gridHash);

		for (uint j = startIndex; j < endIndex; j++) {
			real3 posRadB = FETCH(sortedPosRad, j);
			real4 velMasB = FETCH(sortedVelMas, j);
			real4 rhoPreMuB = FETCH(sortedRhoPreMu, j);
			real3 dist3 = Distance(gridNodePos4, posRadB);
			real_ d = length(dist3);
			real_ mult = velMasB.w / rhoPreMuB.x * W3(d);
			v_share += mult * R3(velMasB); //optimize it ?$
			rp_share += mult * R4(rhoPreMuB.x, rhoPreMuB.y, 0, 0);
		}
	}
}
//--------------------------------------------------------------------------------------------------------------------------------
// calculate grid hash value for each particle
__global__ void calcHashD(uint* gridMarkerHash, // output
		uint* gridMarkerIndex, // output
		real3* posRad, // input: positions
		uint numAllMarkers) {
	uint index = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;
	if (index >= numAllMarkers) return;

	real3 p = posRad[index];

	real3 boxCorner = paramsD.worldOrigin;
	if (p.x < boxCorner.x || p.y < boxCorner.y || p.z < boxCorner.z) {
		printf("Out of Min Boundary\n");
		return;
	}
	boxCorner = paramsD.worldOrigin + paramsD.boxDims;
	if (p.x > boxCorner.x || p.y > boxCorner.y || p.z > boxCorner.z) {
		printf("Out of max Boundary\n");
		return;
	}

	// get address in grid
	int3 gridPos = calcGridPos(p);
	uint hash = calcGridHash(gridPos);

	// store grid hash and particle index
	gridMarkerHash[index] = hash;
	gridMarkerIndex[index] = index;
}
//--------------------------------------------------------------------------------------------------------------------------------

// rearrange particle data into sorted order, and find the start of each cell
// in the sorted hash array
__global__
void reorderDataAndFindCellStartD(
		uint* cellStart, // output: cell start index
		uint* cellEnd, // output: cell end index
		real3* sortedPosRad, // output: sorted positions
		real4* sortedVelMas, // output: sorted velocities
		real4* sortedRhoPreMu,
		uint * gridMarkerHash, // input: sorted grid hashes
		uint * gridMarkerIndex, // input: sorted particle indices
		uint * mapOriginalToSorted, // mapOriginalToSorted[originalIndex] = sortedIndex
		real3* oldPosRad, // input: sorted position array
		real4* oldVelMas, // input: sorted velocity array
		real4* oldRhoPreMu,
		uint numAllMarkers) {
	extern __shared__ uint sharedHash[]; // blockSize + 1 elements
	uint index = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;

	uint hash;
	// handle case when no. of particles not multiple of block size
	if (index < numAllMarkers) {
		hash = gridMarkerHash[index];

		// Load hash data into shared memory so that we can look
		// at neighboring particle's hash value without loading
		// two hash values per thread
		sharedHash[threadIdx.x + 1] = hash;

		if (index > 0 && threadIdx.x == 0) {
			// first thread in block must load neighbor particle hash
			sharedHash[0] = gridMarkerHash[index - 1];
		}
	}

	__syncthreads();

	if (index < numAllMarkers) {
		// If this particle has a different cell index to the previous
		// particle then it must be the first particle in the cell,
		// so store the index of this particle in the cell.
		// As it isn't the first particle, it must also be the cell end of
		// the previous particle's cell

		if (index == 0 || hash != sharedHash[threadIdx.x]) {
			cellStart[hash] = index;
			if (index > 0) cellEnd[sharedHash[threadIdx.x]] = index;
		}

		if (index == numAllMarkers - 1) {
			cellEnd[hash] = index + 1;
		}

		// Now use the sorted index to reorder the pos and vel data
		uint sortedIndex = gridMarkerIndex[index];	  // map sorted to original
		mapOriginalToSorted[sortedIndex] = index;
		real3 posRad = FETCH(oldPosRad, sortedIndex); // macro does either global read or texture fetch
		real4 velMas = FETCH(oldVelMas, sortedIndex); // see particles_kernel.cuh
		real4 rhoPreMu = FETCH(oldRhoPreMu, sortedIndex);

		sortedPosRad[index] = posRad;
		sortedVelMas[index] = velMas;
		sortedRhoPreMu[index] = rhoPreMu;
	}
}
//--------------------------------------------------------------------------------------------------------------------------------
__global__
void newVel_XSPH_D(real3* vel_XSPH_Sorted_D, // output: new velocity
		real3* sortedPosRad, // input: sorted positions
		real4* sortedVelMas, // input: sorted velocities
		real4* sortedRhoPreMu,
		uint* gridMarkerIndex, // input: sorted particle indices
		uint* cellStart,
		uint* cellEnd,
		uint numAllMarkers) {
	uint index = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	if (index >= numAllMarkers) return;

	// read particle data from sorted arrays
	real3 posRadA = FETCH(sortedPosRad, index);
	real4 velMasA = FETCH(sortedVelMas, index);
	real4 rhoPreMuA = FETCH(sortedRhoPreMu, index);
	real3 deltaV = R3(0);

	// get address in grid
	int3 gridPos = calcGridPos(posRadA);

	///if (gridPos.x == paramsD.gridSize.x-1) printf("****aha %d %d\n", gridPos.x, paramsD.gridSize.x);

	// examine neighbouring cells
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				int3 neighbourPos = gridPos + I3(x, y, z);
				deltaV += deltaVShare(neighbourPos, index, posRadA, velMasA, rhoPreMuA, sortedPosRad, sortedVelMas, sortedRhoPreMu, cellStart,
						cellEnd);
			}
		}
	}
	//   // write new velocity back to original unsorted location
	//sortedVel_XSPH[index] = R3(velMasA) + paramsD.EPS_XSPH * deltaV;

	// write new velocity back to original unsorted location
	uint originalIndex = gridMarkerIndex[index];
	vel_XSPH_Sorted_D[index] = R3(velMasA) + paramsD.EPS_XSPH * deltaV;
}
//--------------------------------------------------------------------------------------------------------------------------------
__global__
void collideD(real4* derivVelRhoD, // output: new velocity
		real3* sortedPosRad, // input: sorted positions
		real4* sortedVelMas, // input: sorted velocities
		real3* vel_XSPH_Sorted_D,
		real4* sortedRhoPreMu,

		real3* posRigidD,
		int* rigidIdentifierD,

		uint* gridMarkerIndex, // input: sorted particle indices
		uint* cellStart,
		uint* cellEnd,
		uint numAllMarkers) {
	uint index = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	if (index >= numAllMarkers) return;

	// read particle data from sorted arrays
	real3 posRadA = FETCH(sortedPosRad, index);
	real4 velMasA = FETCH(sortedVelMas, index);
	real4 rhoPreMuA = FETCH(sortedRhoPreMu, index);

	uint originalIndex = gridMarkerIndex[index];
	real3 vel_XSPH_A = FETCH(vel_XSPH_Sorted_D, index);

	real4 derivVelRho =derivVelRhoD[originalIndex];

	// get address in grid
	int3 gridPos = calcGridPos(posRadA);

	// examine neighbouring cells
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			for (int z = -1; z <= 1; z++) {
				derivVelRho += collideCell(gridPos + I3(x, y, z), index, posRadA, velMasA, vel_XSPH_A, rhoPreMuA, sortedPosRad, sortedVelMas, vel_XSPH_Sorted_D,
								sortedRhoPreMu, posRigidD, rigidIdentifierD, cellStart, cellEnd, gridMarkerIndex);
			}
		}
	}

	// write new velocity back to original unsorted location
	// *** let's tweak a little bit :)
	real3 derivV = R3(derivVelRho);

	// Arman move this to integrator instead of collide . take care of action reaction on fluid and solid
	if (length(derivV) > .2 * paramsD.HSML / (dTD_SDK * dTD_SDK)) {
		derivV *= ( .2 * paramsD.HSML / (dTD_SDK * dTD_SDK) ) / length(derivV);
		derivVelRho = R4(derivV, derivVelRho.w);
	}
	if (fabs(derivVelRho.w) > .005 * rhoPreMuA.x / dTD_SDK) {
		derivVelRho.w *= (.005 * rhoPreMuA.x / dTD_SDK) / fabs(derivVelRho.w); //to take care of the sign as well
	}
	// *** end tweak

	derivVelRhoD[originalIndex] = derivVelRho;

	//syncthreads();
}
//--------------------------------------------------------------------------------------------------------------------------------
//calculate particles stresses
__global__ void CalcBCE_Stresses_kernel(
		real3* devStressD,
		real3* volStressD,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real4* sortedRhoPreMu,
		uint* mapOriginalToSorted,
		uint* cellStart,
		uint* cellEnd,
		int numBCE) {
	uint index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= numBCE) {
		return;
	}
	//Arman take care of this
	uint BCE_Index = index + min(numObjectsD.startRigidMarkers, numObjectsD.startRigidMarkers); // updatePortionD = [start, end] index of the update portion
	uint sortedIndex = mapOriginalToSorted[BCE_Index]; //index in the sorted array

	// read particle data from sorted arrays
	real3 posRadA = FETCH(sortedPosRad, sortedIndex);
	real4 velMasA = FETCH(sortedVelMas, sortedIndex);
	real4 rhoPreMuA = FETCH(sortedRhoPreMu, sortedIndex);

	// get address in grid
	int3 gridPos = calcGridPos(posRadA);

	real3 devS3 = R3(0);
	real3 volS3 = R3(0);

	// examine neighbouring cells
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			for (int z = -1; z <= 1; z++) {
				stressCell(devS3, volS3, gridPos + I3(x, y, z), sortedIndex, posRadA, velMasA, rhoPreMuA, sortedPosRad, sortedVelMas, sortedRhoPreMu,
						cellStart, cellEnd);
			}
		}
	}

	devStressD[index] = devS3;
	volStressD[index] = volS3;
}
//--------------------------------------------------------------------------------------------------------------------------------
//calculate particles stresses
__global__ void CalcBCE_MainStresses_kernel(
		real4* mainStressD,
		real3* devStressD,
		real3* volStressD,
		int numBCE) {
	uint index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= numBCE) {
		return;
	}

	real3 devS3 = devStressD[index];
	real3 volS3 = volStressD[index];
	real4 mainS3 = R4(0);
	mainS3.w = sqrt( .5 * (
			pow(volS3.x-volS3.y, 2) + pow(volS3.x-volS3.z, 2) + pow(volS3.y-volS3.z, 2) + 6 * (devS3.x * devS3.x + devS3.y * devS3.y + devS3.z * devS3.z)
			));

	mainStressD[index] = mainS3;
}
//--------------------------------------------------------------------------------------------------------------------------------
//without normalization
__global__
void ReCalcDensityD_F1(
		real3* oldPosRad,
		real4* oldVelMas,
		real4* oldRhoPreMu,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real4* sortedRhoPreMu,
		uint* gridMarkerIndex,
		uint* cellStart,
		uint* cellEnd,
		uint numAllMarkers) {
	uint index = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	if (index >= numAllMarkers) return;

	// read particle data from sorted arrays
	real3 posRadA = FETCH(sortedPosRad, index);
	real4 velMasA = FETCH(sortedVelMas, index);
	real4 rhoPreMuA = FETCH(sortedRhoPreMu, index);

	if (rhoPreMuA.w > -.1) return;

	// get address in grid
	int3 gridPos = calcGridPos(posRadA);

	real_ densityShare = 0.0f;
	real_ denominator = 0.0f;
	// examine neighbouring cells
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				int3 neighbourPos = gridPos + I3(x, y, z);
				collideCellDensityReInit(densityShare, denominator, neighbourPos, index, posRadA, sortedPosRad, sortedVelMas, sortedRhoPreMu, cellStart,
						cellEnd);
			}
		}
	}
	// write new velocity back to original unsorted location
	uint originalIndex = gridMarkerIndex[index];

	real_ newDensity = densityShare + velMasA.w * W3(0); //?$ include the particle in its summation as well
	real_ newDenominator = denominator + velMasA.w * W3(0) / rhoPreMuA.x;
	if (rhoPreMuA.w < 0) {
//		rhoPreMuA.x = newDensity; // old version
		rhoPreMuA.x = newDensity/newDenominator; // correct version
	}
	rhoPreMuA.y = Eos(rhoPreMuA.x, rhoPreMuA.w);
	oldRhoPreMu[originalIndex] = rhoPreMuA;
}
//--------------------------------------------------------------------------------------------------------------------------------
//without normalization
__global__
void ProjectDensityPressureToBCandBCE_D(
		real4* oldRhoPreMu,
		real3* sortedPosRad,
		real4* sortedRhoPreMu,
		uint* gridMarkerIndex,
		uint* cellStart,
		uint* cellEnd,
		uint numAllMarkers) {
	uint index = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	if (index >= numAllMarkers) return;

	// read particle data from sorted arrays
	real3 posRadA = FETCH(sortedPosRad, index);
	real4 rhoPreMuA = FETCH(sortedRhoPreMu, index);

	if (rhoPreMuA.w < -.1) return;

	// get address in grid
	int3 gridPos = calcGridPos(posRadA);

	real3 distRhoPress = R3((RESOLUTION_LENGTH_MULT + 2) * paramsD.HSML, rhoPreMuA.x, rhoPreMuA.y); //(large distance, rhoA, pA)
	// examine neighbouring cells
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				int3 neighbourPos = gridPos + I3(x, y, z);
				projectTheClosestFluidMarker(distRhoPress, neighbourPos, index, posRadA, sortedPosRad, sortedRhoPreMu, cellStart,
						cellEnd);
			}
		}
	}
	// write new velocity back to original unsorted location
	uint originalIndex = gridMarkerIndex[index];
	rhoPreMuA.x = distRhoPress.y;
	rhoPreMuA.y = distRhoPress.z;
	oldRhoPreMu[originalIndex] = rhoPreMuA;
}
//--------------------------------------------------------------------------------------------------------------------------------
//without normalization
__global__
void CalcCartesianDataD(
		real4* rho_Pres_CartD,
		real4* vel_VelMag_CartD,
		real3* sortedPosRad,
		real4* sortedVelMas,
		real4* sortedRhoPreMu,
		uint* gridMarkerIndex,
		uint* cellStart,
		uint* cellEnd) {
	uint index = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	if (index >= cartesianGridDimsD.x * cartesianGridDimsD.y * cartesianGridDimsD.z) return;

	int3 gridLoc;
	gridLoc.z = index / (cartesianGridDimsD.x * cartesianGridDimsD.y);
	gridLoc.y = (index % (cartesianGridDimsD.x * cartesianGridDimsD.y)) / cartesianGridDimsD.x;
	gridLoc.x = (index % (cartesianGridDimsD.x * cartesianGridDimsD.y)) % cartesianGridDimsD.x;
	// alias cartesianGridDimsD = Dim,  you can say:   "index = (Dim.x * Dim.y) * gridLoc.z + Dim.x * gridLoc.y + gridLoc.x"

	// get address in grid
	real3 gridNodePos3 = R3(gridLoc) * resolutionD + paramsD.worldOrigin;
	int3 gridPos = calcGridPos(gridNodePos3);

	real3 vel_share = R3(0.0f);
	real4 rho_pres_share = R4(0.0f);
	// examine neighbouring cells
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				int3 neighbourPos = gridPos + I3(x, y, z);
				calcOnCartesianShare(vel_share, rho_pres_share, neighbourPos, R4(gridNodePos3), sortedPosRad, sortedVelMas, sortedRhoPreMu, cellStart,
						cellEnd);
			}
		}
	}
	// write new velocity back to original unsorted location
	uint originalIndex = gridMarkerIndex[index];

	//real_ newDensity = densityShare + velMasA.w * W3(0); //?$ include the particle in its summation as well
	//if (rhoPreMuA.w < -.1) { rhoPreMuA.x = newDensity; }
	//rhoPreMuA.y = Eos(rhoPreMuA.x, rhoPreMuA.w);
	//   oldRhoPreMu[originalIndex] = rhoPreMuA;
	/////printf("density %f\n", rhoPreMuA.x);
	/////printf("densityshare %f\n", densityShare);
	/////printf("gridPos x y z %d %d %d %f\n", gridPos.x, gridPos.y, gridPos.z, densityShare);
	rho_Pres_CartD[index] = rho_pres_share;
	vel_VelMag_CartD[index] = R4(vel_share, length(vel_share));
}

//%%%%%%%%%%%%%%%%%%%%%%%%
//--------------------------------------------------------------------------------------------------------------------------------
//--------------------------------------------------------------------------------------------------------------------------------
//updates the fluid particles' properties, i.e. velocity, density, pressure, position
__global__ void UpdateFluidD(real3 * posRadD, real4 * velMasD, real3 * vel_XSPH_D, real4 * rhoPresMuD, real4 * derivVelRhoD) {
	uint index = blockIdx.x * blockDim.x + threadIdx.x;
	index += updatePortionD.x; // updatePortionD = [start, end] index of the update portion
	if (index >= updatePortionD.y) {
		return;
	}
	real3 vel_XSPH = vel_XSPH_D[index];
	// 1*** let's tweak a little bit :)
	if (length(vel_XSPH) > .2 * paramsD.HSML / dTD) {
		vel_XSPH *= ( .2 * paramsD.HSML / dTD ) / length(vel_XSPH);
	}
	// 1*** end tweak
	real3 posRad = posRadD[index];
	real3 updatedPositon = posRad + vel_XSPH * dTD;
	posRadD[index] = updatedPositon; //posRadD updated

	real4 derivVelRho = derivVelRhoD[index];
	real4 velMas = velMasD[index];
	real3 updatedVelocity = R3(velMas + derivVelRho * dTD);
	// 2*** let's tweak a little bit :)
	if (length(updatedVelocity) > .2 * paramsD.HSML / dTD) {
		updatedVelocity *= ( .2 * paramsD.HSML / dTD ) / length(updatedVelocity);
	}
	// 2*** end tweak
	velMasD[index] = R4(updatedVelocity, /*rho2 / rhoPresMu.x * */velMas.w); //velMasD updated

	real4 rhoPresMu = rhoPresMuD[index];
	real_ rho2 = rhoPresMu.x + derivVelRho.w * dTD; //rho update. (i.e. rhoPresMu.x), still not wriiten to global matrix
	rhoPresMu.y = Eos(rho2, rhoPresMu.w);
	rhoPresMu.x = rho2;
	rhoPresMuD[index] = rhoPresMu; //rhoPresMuD updated
}
//--------------------------------------------------------------------------------------------------------------------------------
//copies the sortedVelXSPH to velXSPH according to indexing
__global__ void Copy_SortedVelXSPH_To_VelXSPHD(real3 * vel_XSPH_D, real3 * vel_XSPH_Sorted_D, uint * m_dGridMarkerIndex) {
	uint index = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	if (index >= numObjectsD.numAllMarkers) return;
	vel_XSPH_D[m_dGridMarkerIndex[index]] = vel_XSPH_Sorted_D[index];
}

//--------------------------------------------------------------------------------------------------------------------------------
//updates the fluid particles' properties, i.e. velocity, density, pressure, position
__global__ void UpdateKernelBoundary(real3 * posRadD, real4 * velMasD, real4 * rhoPresMuD, real4 * derivVelRhoD) {
	uint index = blockIdx.x * blockDim.x + threadIdx.x;
	index += updatePortionD.x; // updatePortionD = [start, end] index of the update portion
	if (index >= updatePortionD.y) {
		return;
	}

	real4 derivVelRho = derivVelRhoD[index];
	real4 rhoPresMu = rhoPresMuD[index];
	real_ rho2 = rhoPresMu.x + derivVelRho.w * dTD; //rho update. (i.e. rhoPresMu.x), still not wriiten to global matrix
	rhoPresMu.y = Eos(rho2, rhoPresMu.w);
	rhoPresMu.x = rho2;
	rhoPresMuD[index] = rhoPresMu; //rhoPresMuD updated
}


//--------------------------------------------------------------------------------------------------------------------------------
//applies periodic BC along x
__global__ void ApplyPeriodicBoundaryXKernel(real3 * posRadD, real4 * rhoPresMuD) {
	uint index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= numObjectsD.numAllMarkers) {
		return;
	}
	real4 rhoPresMu = rhoPresMuD[index];
	if (fabs(rhoPresMu.w) < .1) {
		return;
	} //no need to do anything if it is a boundary particle
	real3 posRad = posRadD[index];
	if (posRad.x > paramsD.cMax.x) {
		posRad.x -= (paramsD.cMax.x - paramsD.cMin.x);
		posRadD[index] = posRad;
		if (rhoPresMu.w < -.1) {
			rhoPresMu.y = rhoPresMu.y + paramsD.deltaPress.x;
			rhoPresMuD[index] = rhoPresMu;
		}
		return;
	}
	if (posRad.x < paramsD.cMin.x) {
		posRad.x += (paramsD.cMax.x - paramsD.cMin.x);
		posRadD[index] = posRad;
		if (rhoPresMu.w < -.1) {
			rhoPresMu.y = rhoPresMu.y - paramsD.deltaPress.x;
			rhoPresMuD[index] = rhoPresMu;
		}
		return;
	}
}
//--------------------------------------------------------------------------------------------------------------------------------
//applies periodic BC along y
__global__ void ApplyPeriodicBoundaryYKernel(real3 * posRadD, real4 * rhoPresMuD) {
	uint index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= numObjectsD.numAllMarkers) {
		return;
	}
	real4 rhoPresMu = rhoPresMuD[index];
	if (fabs(rhoPresMu.w) < .1) {
		return;
	} //no need to do anything if it is a boundary particle
	real3 posRad = posRadD[index];
	if (posRad.y > paramsD.cMax.y) {
		posRad.y -= (paramsD.cMax.y - paramsD.cMin.y);
		posRadD[index] = posRad;
		if (rhoPresMu.w < -.1) {
			rhoPresMu.y = rhoPresMu.y + paramsD.deltaPress.y;
			rhoPresMuD[index] = rhoPresMu;
		}
		return;
	}
	if (posRad.y < paramsD.cMin.y) {
		posRad.y += (paramsD.cMax.y - paramsD.cMin.y);
		posRadD[index] = posRad;
		if (rhoPresMu.w < -.1) {
			rhoPresMu.y = rhoPresMu.y - paramsD.deltaPress.y;
			rhoPresMuD[index] = rhoPresMu;
		}
		return;
	}
}
//--------------------------------------------------------------------------------------------------------------------------------
//applies periodic BC along z
__global__ void ApplyPeriodicBoundaryZKernel(real3 * posRadD, real4 * rhoPresMuD) {
	uint index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= numObjectsD.numAllMarkers) {
		return;
	}
	real4 rhoPresMu = rhoPresMuD[index];
	if (fabs(rhoPresMu.w) < .1) {
		return;
	} //no need to do anything if it is a boundary particle
	real3 posRad = posRadD[index];
	if (posRad.z > paramsD.cMax.z) {
		posRad.z -= (paramsD.cMax.z - paramsD.cMin.z);
		posRadD[index] = posRad;
		if (rhoPresMu.w < -.1) {
			rhoPresMu.y = rhoPresMu.y + paramsD.deltaPress.z;
			rhoPresMuD[index] = rhoPresMu;
		}
		return;
	}
	if (posRad.z < paramsD.cMin.z) {
		posRad.z += (paramsD.cMax.z - paramsD.cMin.z);
		posRadD[index] = posRad;
		if (rhoPresMu.w < -.1) {
			rhoPresMu.y = rhoPresMu.y - paramsD.deltaPress.z;
			rhoPresMuD[index] = rhoPresMu;
		}
		return;
	}
}



//%%%%%%%%%%%%%%%%%%%%%%%%








//--------------------------------------------------------------------------------------------------------------------------------
void allocateArray(void **devPtr, size_t size) {
	cutilSafeCall(cudaMalloc(devPtr, size));
}
//--------------------------------------------------------------------------------------------------------------------------------
void freeArray(void *devPtr) {
	cutilSafeCall(cudaFree(devPtr));
}
//--------------------------------------------------------------------------------------------------------------------------------
//Round a / b to nearest higher integer value
uint iDivUp(uint a, uint b) {
	return (a % b != 0) ? (a / b + 1) : (a / b);
}
//--------------------------------------------------------------------------------------------------------------------------------
// compute grid and thread block size for a given number of elements
void computeGridSize(uint n, uint blockSize, uint &numBlocks, uint &numThreads) {
	uint n2 = (n == 0) ? 1 : n;
	numThreads = min(blockSize, n2);
	numBlocks = iDivUp(n2, numThreads);
}
//--------------------------------------------------------------------------------------------------------------------------------
void setParameters(SimParams *hostParams, NumberOfObjects *numObjects) {
	// copy parameters to constant memory
	cutilSafeCall( cudaMemcpyToSymbolAsync(paramsD, hostParams, sizeof(SimParams)));
	cutilSafeCall( cudaMemcpyToSymbolAsync(numObjectsD, numObjects, sizeof(NumberOfObjects)));
}
//--------------------------------------------------------------------------------------------------------------------------------
void calcHash(
		thrust::device_vector<uint>   & gridMarkerHash,
		thrust::device_vector<uint>   & gridMarkerIndex,
		thrust::device_vector<real3>  & posRad,
		int numAllMarkers) {
	uint numThreads, numBlocks;
	computeGridSize(numAllMarkers, 256, numBlocks, numThreads);

	// execute the kernel
	calcHashD<<< numBlocks, numThreads >>>(
			U1CAST(gridMarkerHash),
			U1CAST(gridMarkerIndex),
			R3CAST(posRad),
			numAllMarkers);

	// check if kernel invocation generated an error
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: calcHash");
}
//--------------------------------------------------------------------------------------------------------------------------------
void reorderDataAndFindCellStart(
		thrust::device_vector<uint>  & cellStart,
		thrust::device_vector<uint>  & cellEnd,
		thrust::device_vector<real3> & sortedPosRad,
		thrust::device_vector<real4> & sortedVelMas,
		thrust::device_vector<real4> & sortedRhoPreMu,

		thrust::device_vector<uint>  & gridMarkerHash,
		thrust::device_vector<uint>  & gridMarkerIndex,

		thrust::device_vector<uint>  & mapOriginalToSorted,

		thrust::device_vector<real3> & oldPosRad,
		thrust::device_vector<real4> & oldVelMas,
		thrust::device_vector<real4> & oldRhoPreMu,
		uint numAllMarkers,
		uint numCells) {
	uint numThreads, numBlocks;
	computeGridSize(numAllMarkers, 256, numBlocks, numThreads); //?$ 256 is blockSize


	// set all cells to empty
	cutilSafeCall(cudaMemset(U1CAST(cellStart), 0xffffffff, numCells*sizeof(uint)));

//#if USE_TEX
//#if 0
//    cutilSafeCall(cudaBindTexture(0, oldPosTex, oldPosRad, numAllMarkers*sizeof(real4)));
//    cutilSafeCall(cudaBindTexture(0, oldVelTex, oldVelMas, numAllMarkers*sizeof(real4)));
//#endif

	uint smemSize = sizeof(uint) * (numThreads + 1);
	reorderDataAndFindCellStartD<<< numBlocks, numThreads, smemSize>>>(
			U1CAST(cellStart),
			U1CAST(cellEnd),
			R3CAST(sortedPosRad),
			R4CAST(sortedVelMas),
			R4CAST(sortedRhoPreMu),
			U1CAST(gridMarkerHash),
			U1CAST(gridMarkerIndex),
			U1CAST(mapOriginalToSorted),
			R3CAST(oldPosRad),
			R4CAST(oldVelMas),
			R4CAST(oldRhoPreMu),
			numAllMarkers);
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: reorderDataAndFindCellStartD");
//#if USE_TEX
//#if 0
//    cutilSafeCall(cudaUnbindTexture(oldPosTex));
//    cutilSafeCall(cudaUnbindTexture(oldVelTex));
//#endif
}
//--------------------------------------------------------------------------------------------------------------------------------
void RecalcVelocity_XSPH(
		thrust::device_vector<real3> & vel_XSPH_Sorted_D,
		thrust::device_vector<real3> & sortedPosRad,
		thrust::device_vector<real4> & sortedVelMas,
		thrust::device_vector<real4> & sortedRhoPreMu,
		thrust::device_vector<uint>  & gridMarkerIndex,
		thrust::device_vector<uint>  & cellStart,
		thrust::device_vector<uint>  & cellEnd,
		uint numAllMarkers,
		uint numCells) {
	//#if USE_TEX
	//    cutilSafeCall(cudaBindTexture(0, oldPosTex, sortedPosRad, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, oldVelTex, sortedVelMas, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, cellStartTex, cellStart, numCells*sizeof(uint)));
	//    cutilSafeCall(cudaBindTexture(0, cellEndTex, cellEnd, numCells*sizeof(uint)));    
	//#endif

	// thread per particle
	uint numThreads, numBlocks;
	computeGridSize(numAllMarkers, 64, numBlocks, numThreads);

	// execute the kernel
	newVel_XSPH_D<<< numBlocks, numThreads >>>(
			R3CAST(vel_XSPH_Sorted_D),
			R3CAST(sortedPosRad),
			R4CAST(sortedVelMas),
			R4CAST(sortedRhoPreMu),
			U1CAST(gridMarkerIndex),
			U1CAST(cellStart),
			U1CAST(cellEnd),
			numAllMarkers);

	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: newVel_XSPH_D");

	//#if USE_TEX
	//    cutilSafeCall(cudaUnbindTexture(oldPosTex));
	//    cutilSafeCall(cudaUnbindTexture(oldVelTex));
	//    cutilSafeCall(cudaUnbindTexture(cellStartTex));
	//    cutilSafeCall(cudaUnbindTexture(cellEndTex));
	//#endif
}
//--------------------------------------------------------------------------------------------------------------------------------
void CalcBCE_Stresses(
		thrust::device_vector<real3> & devStressD,
		thrust::device_vector<real3> & volStressD,
		thrust::device_vector<real4> & mainStressD,
		thrust::device_vector<real3> & sortedPosRad,
		thrust::device_vector<real4> & sortedVelMas,
		thrust::device_vector<real4> & sortedRhoPreMu,
		thrust::device_vector<uint>  & mapOriginalToSorted,
		thrust::device_vector<uint>  & cellStart,
		thrust::device_vector<uint>  & cellEnd,
		int numBCE) {

	// thread per particle
	uint numThreads, numBlocks;
	computeGridSize(numBCE, 128, numBlocks, numThreads);
	CalcBCE_Stresses_kernel<<<numBlocks, numThreads>>>(R3CAST(devStressD), R3CAST(volStressD), R3CAST(sortedPosRad), R4CAST(sortedVelMas), R4CAST(sortedRhoPreMu),
			U1CAST(mapOriginalToSorted), U1CAST(cellStart), U1CAST(cellEnd), numBCE);

	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: CalcBCE_Stresses_kernel");

	CalcBCE_MainStresses_kernel<<<numBlocks, numThreads>>>(R4CAST(mainStressD), R3CAST(devStressD), R3CAST(volStressD), numBCE);

	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: CalcBCE_MainStresses_kernel");
}
//--------------------------------------------------------------------------------------------------------------------------------
void collide(
		thrust::device_vector<real4> & derivVelRhoD,
		thrust::device_vector<real3> & sortedPosRad,
		thrust::device_vector<real4> & sortedVelMas,
		thrust::device_vector<real3> & vel_XSPH_Sorted_D,
		thrust::device_vector<real4> & sortedRhoPreMu,
		const thrust::device_vector<real3> & posRigidD,
		const thrust::device_vector<int>   & rigidIdentifierD,
		thrust::device_vector<uint>  & gridMarkerIndex,
		thrust::device_vector<uint>  & cellStart,
		thrust::device_vector<uint>  & cellEnd,
		uint numAllMarkers,
		uint numCells,
		real_ dT) {
	//#if USE_TEX
	//    cutilSafeCall(cudaBindTexture(0, oldPosTex, sortedPosRad, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, oldVelTex, sortedVelMas, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, cellStartTex, cellStart, numCells*sizeof(uint)));
	//    cutilSafeCall(cudaBindTexture(0, cellEndTex, cellEnd, numCells*sizeof(uint)));    
	//#endif

	cudaMemcpyToSymbolAsync(dTD_SDK, &dT, sizeof(dT));

	// thread per particle
	uint numThreads, numBlocks;
	computeGridSize(numAllMarkers, 64, numBlocks, numThreads);

	// execute the kernel
	collideD<<< numBlocks, numThreads >>>(
			R4CAST(derivVelRhoD),
			R3CAST(sortedPosRad),
			R4CAST(sortedVelMas),
			R3CAST(vel_XSPH_Sorted_D),
			R4CAST(sortedRhoPreMu),
			R3CAST(posRigidD),
			I1CAST(rigidIdentifierD),
			U1CAST(gridMarkerIndex),
			U1CAST(cellStart),
			U1CAST(cellEnd),
			numAllMarkers);

	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: collideD");

	//#if USE_TEX
	//    cutilSafeCall(cudaUnbindTexture(oldPosTex));
	//    cutilSafeCall(cudaUnbindTexture(oldVelTex));
	//    cutilSafeCall(cudaUnbindTexture(cellStartTex));
	//    cutilSafeCall(cudaUnbindTexture(cellEndTex));
	//#endif
}
//--------------------------------------------------------------------------------------------------------------------------------
void ReCalcDensity(
		thrust::device_vector<real3> & oldPosRad,
		thrust::device_vector<real4> & oldVelMas,
		thrust::device_vector<real4> & oldRhoPreMu,
		thrust::device_vector<real3> & sortedPosRad,
		thrust::device_vector<real4> & sortedVelMas,
		thrust::device_vector<real4> & sortedRhoPreMu,
		thrust::device_vector<uint>  & gridMarkerIndex,
		thrust::device_vector<uint>  & cellStart,
		thrust::device_vector<uint>  & cellEnd,
		uint numAllMarkers) {
	//#if USE_TEX
	//    cutilSafeCall(cudaBindTexture(0, oldPosTex, sortedPosRad, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, oldVelTex, sortedVelMas, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, cellStartTex, cellStart, numCells*sizeof(uint)));
	//    cutilSafeCall(cudaBindTexture(0, cellEndTex, cellEnd, numCells*sizeof(uint)));    
	//#endif

	// thread per particle
	uint numThreads, numBlocks;
	computeGridSize(numAllMarkers, 64, numBlocks, numThreads);

	// execute the kernel
	ReCalcDensityD_F1<<< numBlocks, numThreads >>>(
			R3CAST(oldPosRad),
			R4CAST(oldVelMas),
			R4CAST(oldRhoPreMu),
			R3CAST(sortedPosRad),
			R4CAST(sortedVelMas),
			R4CAST(sortedRhoPreMu),
			U1CAST(gridMarkerIndex),
			U1CAST(cellStart),
			U1CAST(cellEnd),
			numAllMarkers);

	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: ReCalcDensityD");

	//#if USE_TEX
	//    cutilSafeCall(cudaUnbindTexture(oldPosTex));
	//    cutilSafeCall(cudaUnbindTexture(oldVelTex));
	//    cutilSafeCall(cudaUnbindTexture(cellStartTex));
	//    cutilSafeCall(cudaUnbindTexture(cellEndTex));
	//#endif
}
//--------------------------------------------------------------------------------------------------------------------------------
void ProjectDensityPressureToBCandBCE(
		thrust::device_vector<real4> &  oldRhoPreMu,
		thrust::device_vector<real3> &  sortedPosRad,
		thrust::device_vector<real4> &  sortedRhoPreMu,
		thrust::device_vector<uint>  & gridMarkerIndex,
		thrust::device_vector<uint>  & cellStart,
		thrust::device_vector<uint>  & cellEnd,
		uint numAllMarkers) {
	//#if USE_TEX
	//    cutilSafeCall(cudaBindTexture(0, oldPosTex, sortedPosRad, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, oldVelTex, sortedVelMas, numAllMarkers*sizeof(real4)));
	//    cutilSafeCall(cudaBindTexture(0, cellStartTex, cellStart, numCells*sizeof(uint)));
	//    cutilSafeCall(cudaBindTexture(0, cellEndTex, cellEnd, numCells*sizeof(uint)));
	//#endif

	// thread per particle
	uint numThreads, numBlocks;
	computeGridSize(numAllMarkers, 64, numBlocks, numThreads);

	// execute the kernel
	ProjectDensityPressureToBCandBCE_D<<< numBlocks, numThreads >>>(
			R4CAST(oldRhoPreMu),
			R3CAST(sortedPosRad),
			R4CAST(sortedRhoPreMu),
			U1CAST(gridMarkerIndex),
			U1CAST(cellStart),
			U1CAST(cellEnd),
			numAllMarkers);

	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: ReCalcDensityD");

	//#if USE_TEX
	//    cutilSafeCall(cudaUnbindTexture(oldPosTex));
	//    cutilSafeCall(cudaUnbindTexture(oldVelTex));
	//    cutilSafeCall(cudaUnbindTexture(cellStartTex));
	//    cutilSafeCall(cudaUnbindTexture(cellEndTex));
	//#endif
}
//--------------------------------------------------------------------------------------------------------------------------------
void CalcCartesianData(
		thrust::device_vector<real4> & rho_Pres_CartD,
		thrust::device_vector<real4> & vel_VelMag_CartD,
		thrust::device_vector<real3> & sortedPosRad,
		thrust::device_vector<real4> & sortedVelMas,
		thrust::device_vector<real4> & sortedRhoPreMu,
		thrust::device_vector<uint>  & gridMarkerIndex,
		thrust::device_vector<uint>  & cellStart,
		thrust::device_vector<uint>  & cellEnd,
		uint cartesianGridSize,
		int3 cartesianGridDims,
		real_ resolution) {

	cutilSafeCall( cudaMemcpyToSymbolAsync(cartesianGridDimsD, &cartesianGridDims, sizeof(cartesianGridDims)));
	cutilSafeCall( cudaMemcpyToSymbolAsync(resolutionD, &resolution, sizeof(resolution)));

	// thread per particle
	uint numThreads, numBlocks;
	computeGridSize(cartesianGridSize, 64, numBlocks, numThreads);

	// execute the kernel
	CalcCartesianDataD<<< numBlocks, numThreads >>>(
			R4CAST(rho_Pres_CartD), R4CAST(vel_VelMag_CartD), R3CAST(sortedPosRad), R4CAST(sortedVelMas), R4CAST(sortedRhoPreMu),
					U1CAST(gridMarkerIndex), U1CAST(cellStart), U1CAST(cellEnd));

	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: ReCalcDensityD");

	//#if USE_TEX
	//    cutilSafeCall(cudaUnbindTexture(oldPosTex));
	//    cutilSafeCall(cudaUnbindTexture(oldVelTex));
	//    cutilSafeCall(cudaUnbindTexture(cellStartTex));
	//    cutilSafeCall(cudaUnbindTexture(cellEndTex));
	//#endif
}

//%%%%%%%%%%%%%%%%%%%%%%%%%%
//--------------------------------------------------------------------------------------------------------------------------------
//updates the fluid particles by calling UpdateFluidD
void UpdateFluid(
		thrust::device_vector<real3> & posRadD,
		thrust::device_vector<real4> & velMasD,
		thrust::device_vector<real3> & vel_XSPH_D,
		thrust::device_vector<real4> & rhoPresMuD,
		thrust::device_vector<real4> & derivVelRhoD,
		const thrust::host_vector<int3> & referenceArray,
		real_ dT) {
	int3 referencePortion = referenceArray[0];
	if (referencePortion.z != -1) {
		printf("error in UpdateFluid, accessing non fluid\n");
		return;
	}
	int2 updatePortion = I2(referencePortion);
	//int2 updatePortion = I2(referenceArray[0].x, referenceArray[0].y);
	cudaMemcpyToSymbolAsync(dTD, &dT, sizeof(dT));
	cudaMemcpyToSymbolAsync(updatePortionD, &updatePortion, sizeof(updatePortion));

	uint nBlock_UpdateFluid, nThreads;
	computeGridSize(updatePortion.y - updatePortion.x, 128, nBlock_UpdateFluid, nThreads);
	UpdateFluidD<<<nBlock_UpdateFluid, nThreads>>>(R3CAST(posRadD), R4CAST(velMasD), R3CAST(vel_XSPH_D), R4CAST(rhoPresMuD), R4CAST(derivVelRhoD));
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: UpdateFluidD");
}
//--------------------------------------------------------------------------------------------------------------------------------
void Copy_SortedVelXSPH_To_VelXSPH(
		thrust::device_vector<real3> & vel_XSPH_D,
		thrust::device_vector<real3> & vel_XSPH_Sorted_D,
		thrust::device_vector<uint> & m_dGridMarkerIndex,
		int numAllMarkers) {
	uint nBlock_NumSpheres, nThreads_SphMarkers;
	computeGridSize(numAllMarkers, 256, nBlock_NumSpheres, nThreads_SphMarkers);
	Copy_SortedVelXSPH_To_VelXSPHD<<<nBlock_NumSpheres, nThreads_SphMarkers>>>(R3CAST(vel_XSPH_D), R3CAST(vel_XSPH_Sorted_D), U1CAST(m_dGridMarkerIndex));
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: Copy_SortedVelXSPH_To_VelXSPH");
}
//--------------------------------------------------------------------------------------------------------------------------------
//updates the fluid particles by calling UpdateBoundary
void UpdateBoundary(
		thrust::device_vector<real3> & posRadD,
		thrust::device_vector<real4> & velMasD,
		thrust::device_vector<real4> & rhoPresMuD,
		thrust::device_vector<real4> & derivVelRhoD,
		const thrust::host_vector<int3> & referenceArray,
		real_ dT) {
	int3 referencePortion = referenceArray[1];
	if (referencePortion.z != 0) {
		printf("error in UpdateBoundary, accessing non boundary\n");
		return;
	}
	int2 updatePortion = I2(referencePortion);
	cudaMemcpyToSymbolAsync(dTD, &dT, sizeof(dT));
	cudaMemcpyToSymbolAsync(updatePortionD, &updatePortion, sizeof(updatePortion));

	uint nBlock_UpdateFluid, nThreads;
	computeGridSize(updatePortion.y - updatePortion.x, 128, nBlock_UpdateFluid, nThreads);
	UpdateKernelBoundary<<<nBlock_UpdateFluid, nThreads>>>(R3CAST(posRadD), R4CAST(velMasD), R4CAST(rhoPresMuD), R4CAST(derivVelRhoD));
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: UpdateKernelBoundary");
}

//--------------------------------------------------------------------------------------------------------------------------------
void ApplyBoundarySPH_Markers(
		thrust::device_vector<real3> & posRadD,
		thrust::device_vector<real4> & rhoPresMuD,
		int numAllMarkers) {
	uint nBlock_NumSpheres, nThreads_SphMarkers;
	computeGridSize(numAllMarkers, 256, nBlock_NumSpheres, nThreads_SphMarkers);
	ApplyPeriodicBoundaryXKernel<<<nBlock_NumSpheres, nThreads_SphMarkers>>>(R3CAST(posRadD), R4CAST(rhoPresMuD));
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: ApplyPeriodicBoundaryXKernel");
	// these are useful anyway for out of bound particles
	ApplyPeriodicBoundaryYKernel<<<nBlock_NumSpheres, nThreads_SphMarkers>>>(R3CAST(posRadD), R4CAST(rhoPresMuD));
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: ApplyPeriodicBoundaryYKernel");
	ApplyPeriodicBoundaryZKernel<<<nBlock_NumSpheres, nThreads_SphMarkers>>>(R3CAST(posRadD), R4CAST(rhoPresMuD));
	cudaThreadSynchronize();
	CUT_CHECK_ERROR("Kernel execution failed: ApplyPeriodicBoundaryZKernel");

//	SetOutputPressureToZero_X<<<nBlock_NumSpheres, nThreads_SphMarkers>>>(R3CAST(posRadD), R4CAST(rhoPresMuD));
//	cudaThreadSynchronize();
//	CUT_CHECK_ERROR("Kernel execution failed: SetOutputPressureToZero");
}
