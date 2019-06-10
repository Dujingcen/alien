#pragma once

#include "device_functions.h"
#include "sm_60_atomic_functions.h"

#include "ModelBasic/ElementaryTypes.h"

#include "CudaAccessTOs.cuh"
#include "CudaConstants.cuh"
#include "Base.cuh"
#include "Map.cuh"

#include "SimulationData.cuh"

class EntityFactory
{
private:
    BasicMap _map;
    SimulationData* _data;

public:
    __inline__ __device__ void init(SimulationData* data);
    __inline__ __device__ void createClusterFromTO_blockCall(
        ClusterAccessTO const& clusterTO,
        DataAccessTO const* _simulationTO);
    __inline__ __device__ void createParticleFromTO(
        ParticleAccessTO const& particleTO,
        DataAccessTO const* _simulationTO);
    __inline__ __device__ void createClusterWithRandomCell(float energy, float2 const& pos, float2 const& vel);
    __inline__ __device__ void createParticle(float energy, float2 const& pos, float2 const& vel);
};

/************************************************************************/
/* Implementation                                                       */
/************************************************************************/

__inline__ __device__ void EntityFactory::init(SimulationData* data)
{
    _data = data;
    _map.init(data->size);
}

__inline__ __device__ void EntityFactory::createClusterFromTO_blockCall(ClusterAccessTO const& clusterTO, DataAccessTO const* _simulationTO)
{
    __shared__ Cluster* cluster;
    __shared__ Cell* cells;
    __shared__ float angularMass;
    __shared__ float invRotMatrix[2][2];
    __shared__ float2 posCorrection;

    if (0 == threadIdx.x) {
        cluster = _data->clustersNew.getNewElement();
        cluster->id = clusterTO.id;
        cluster->pos = clusterTO.pos;
        _map.mapPosCorrection(cluster->pos);
        posCorrection = Math::sub(cluster->pos, clusterTO.pos);
        cluster->vel = clusterTO.vel;
        cluster->angle = clusterTO.angle;
        cluster->angularVel = clusterTO.angularVel;
        cluster->maxCellPointers = clusterTO.numCells * CELL_POINTER_CAPACITY_MULTIPLIER;
        cluster->numCellPointers = clusterTO.numCells;
        cluster->cellPointers = _data->cellPointers.getNewSubarray(cluster->maxCellPointers);
        cells = _data->cells.getNewSubarray(cluster->numCellPointers);
        cluster->numTokens = clusterTO.numTokens;
        cluster->tokens = _data->tokensNew.getNewSubarray(cluster->numTokens);

        cluster->decompositionRequired = false;
        cluster->locked = 0;
        cluster->clusterToFuse = nullptr;

        angularMass = 0.0f;
        Math::inverseRotationMatrix(cluster->angle, invRotMatrix);
    }
    __syncthreads();

    int startCellIndex;
    int endCellIndex;
    calcPartition(cluster->numCellPointers, threadIdx.x, blockDim.x, startCellIndex, endCellIndex);

    for (auto cellIndex = startCellIndex; cellIndex <= endCellIndex; ++cellIndex) {
        auto& cell = cells[cellIndex];
        cluster->cellPointers[cellIndex] = &cell;
        auto const& cellTO = _simulationTO->cells[clusterTO.cellStartIndex + cellIndex];
        cell.id = cellTO.id;
        cell.cluster = cluster;
        cell.absPos = Math::add(cellTO.pos, posCorrection);

        float2 deltaPos = Math::sub(cell.absPos, clusterTO.pos);
        cell.relPos.x = deltaPos.x*invRotMatrix[0][0] + deltaPos.y*invRotMatrix[0][1];
        cell.relPos.y = deltaPos.x*invRotMatrix[1][0] + deltaPos.y*invRotMatrix[1][1];
        atomicAdd(&angularMass, Math::lengthSquared(cell.relPos));

        auto r = Math::sub(cell.absPos, cluster->pos);
        _map.mapDisplacementCorrection(r);
        cell.vel = Physics::tangentialVelocity(r, cluster->vel, cluster->angularVel);

        cell.energy = cellTO.energy;
        cell.branchNumber = cellTO.branchNumber;
        cell.tokenBlocked = cellTO.tokenBlocked;
        cell.maxConnections = cellTO.maxConnections;
        cell.numConnections = cellTO.numConnections;
        for (int i = 0; i < cell.numConnections; ++i) {
            int index = cellTO.connectionIndices[i] - clusterTO.cellStartIndex;
            cell.connections[i] = cells + index;
        }

        cell.cellFunctionType = cellTO.cellFunctionType;

        switch (static_cast<Enums::CellFunction::Type>(cell.cellFunctionType)) {
        case Enums::CellFunction::COMPUTER: {
            cell.numStaticBytes = cellTO.numStaticBytes;
            cell.numMutableBytes = cudaSimulationParameters.cellFunctionComputerCellMemorySize;
        } break;
        case Enums::CellFunction::SENSOR: {
            cell.numStaticBytes = 0;
            cell.numMutableBytes = 5;
        } break;
        default: {
            cell.numStaticBytes = 0;
            cell.numMutableBytes = 0;
        }
        }
        for (int i = 0; i < MAX_CELL_STATIC_BYTES; ++i) {
            cell.staticData[i] = cellTO.staticData[i];
        }
        for (int i = 0; i < MAX_CELL_MUTABLE_BYTES; ++i) {
            cell.mutableData[i] = cellTO.mutableData[i];
        }

        cell.protectionCounter = 0;
        cell.alive = true;
        cell.locked = 0;
    }

    int startTokenIndex;
    int endTokenIndex;
    calcPartition(cluster->numTokens, threadIdx.x, blockDim.x, startTokenIndex, endTokenIndex);

    for (auto tokenIndex = startTokenIndex; tokenIndex <= endTokenIndex; ++tokenIndex) {
        Token& token = cluster->tokens[tokenIndex];
        TokenAccessTO const& tokenTO = _simulationTO->tokens[clusterTO.tokenStartIndex + tokenIndex];

        token.energy = tokenTO.energy;
        for (int i = 0; i < cudaSimulationParameters.tokenMemorySize; ++i) {
            token.memory[i] = tokenTO.memory[i];
        }
        int index = tokenTO.cellIndex - clusterTO.cellStartIndex;
        token.cell = cells + index;
    }

    __syncthreads();

    if (0 == threadIdx.x) {
        cluster->angularMass = angularMass;
    }
}

__inline__ __device__ void EntityFactory::createParticleFromTO(ParticleAccessTO const& particleTO, DataAccessTO const* _simulationTO)
{
    Particle* particle = _data->particlesNew.getNewElement();
    particle->id = particleTO.id;
    particle->pos = particleTO.pos;
    _map.mapPosCorrection(particle->pos);
    particle->vel = particleTO.vel;
    particle->energy = particleTO.energy;
    particle->locked = 0;
    particle->alive = true;
}

__inline__ __device__ void EntityFactory::createClusterWithRandomCell(float energy, float2 const & pos, float2 const & vel)
{
    auto cluster = _data->clustersNew.getNewElement();
    auto cell = _data->cells.getNewElement();
    auto cellPointers = _data->cellPointers.getNewSubarray(CELL_POINTER_CAPACITY_MULTIPLIER);

    cluster->id = _data->numberGen.createNewId_kernel();
    cluster->pos = pos;
    cluster->vel = vel;
    cluster->angle = 0.0f;
    cluster->angularVel = 0.0f;
    cluster->angularMass = 0.0f;
    cluster->maxCellPointers = CELL_POINTER_CAPACITY_MULTIPLIER;
    cluster->numCellPointers = 1;
    cluster->cellPointers = cellPointers;
    *cellPointers = cell;
    cluster->numTokens = 0;

    cluster->clusterToFuse = nullptr;
    cluster->locked = 0;
    cluster->decompositionRequired = false;

    cell->id = _data->numberGen.createNewId_kernel();
    cell->absPos = pos;
    cell->relPos = { 0.0f, 0.0f };
    cell->vel = vel;
    cell->energy = energy;
    cell->maxConnections = _data->numberGen.random(MAX_CELL_BONDS);
    cell->cluster = cluster;
    cell->branchNumber = _data->numberGen.random(cudaSimulationParameters.cellMaxTokenBranchNumber - 1);
    cell->numConnections = 0;
    cell->tokenBlocked = false;
    cell->alive = true;
    cell->protectionCounter = 0;
    cell->locked = 0;
    cell->cellFunctionType = _data->numberGen.random(static_cast<int>(Enums::CellFunction::_COUNTER) - 1);
    switch (static_cast<Enums::CellFunction::Type>(cell->cellFunctionType)) {
    case Enums::CellFunction::COMPUTER: {
        cell->numStaticBytes = cudaSimulationParameters.cellFunctionComputerMaxInstructions*3;
        cell->numMutableBytes = cudaSimulationParameters.cellFunctionComputerCellMemorySize;
    } break;
    case Enums::CellFunction::SENSOR: {
        cell->numStaticBytes = 0;
        cell->numMutableBytes = 5;
    } break;
    default: {
        cell->numStaticBytes = 0;
        cell->numMutableBytes = 0;
    }
    }
    for (int i = 0; i < MAX_CELL_STATIC_BYTES; ++i) {
        cell->staticData[i] = _data->numberGen.random(255);
    }
    for (int i = 0; i < MAX_CELL_MUTABLE_BYTES; ++i) {
        cell->mutableData[i] = _data->numberGen.random(255);
    }
}

__inline__ __device__ void EntityFactory::createParticle(float energy, float2 const & pos, float2 const & vel)
{
    Particle* particle = _data->particlesNew.getNewElement();
    particle->id = _data->numberGen.createNewId_kernel();
    particle->locked = 0;
    particle->alive = true;
    particle->energy = energy;
    particle->pos = pos;
    particle->vel = vel;
}
