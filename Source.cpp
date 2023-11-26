#include "pch.h"

struct FileHeader {
	uint32_t HeaderSize;
	uint32_t Type;
	uint32_t RawFileSize;
	uint32_t UsedBlocks;
	uint32_t AllocatedBlocks;
	uint32_t LodBlockCount;
};

struct LodBlock {
	uint32_t CompressedOffset;
	uint32_t CompressedSize;
	uint32_t DecompressedSize;
	uint32_t BlockOffset;
	uint32_t BlockCount;
};

int main() {
	// Enable debug
	CComPtr<ID3D12Debug> d3d12debug;
	if (auto hr = D3D12GetDebugInterface(IID_PPV_ARGS(&d3d12debug)); FAILED(hr))
		return hr;
	d3d12debug->EnableDebugLayer();

	// Create device
	const D3D_FEATURE_LEVEL lvl[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0 };
	CComPtr<ID3D12Device> device;
	if (auto hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)); FAILED(hr))
		return hr;

	// Create root signature
	D3D12_DESCRIPTOR_RANGE ranges[] {
		{
			.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
			.NumDescriptors = 1,
			.BaseShaderRegister = 0,
			.RegisterSpace = 0,
			.OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND,
		},
		{
			.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV,
			.NumDescriptors = 1,
			.BaseShaderRegister = 0,
			.RegisterSpace = 0,
			.OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND,
		}
	};
	D3D12_ROOT_PARAMETER rootParameters[] {
		{
			.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
			.DescriptorTable = {.NumDescriptorRanges = 1, .pDescriptorRanges = &ranges[0] },
			.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL,
		},
		{
			.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
			.DescriptorTable = {.NumDescriptorRanges = 1, .pDescriptorRanges = &ranges[1] },
			.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL,
		}
	};
	D3D12_ROOT_SIGNATURE_DESC computeRootSignatureDesc {
		.NumParameters = (UINT)(sizeof(rootParameters) / sizeof(rootParameters[0])),
		.pParameters = rootParameters,
		.NumStaticSamplers = 0,
		.Flags = D3D12_ROOT_SIGNATURE_FLAG_DENY_VERTEX_SHADER_ROOT_ACCESS
			| D3D12_ROOT_SIGNATURE_FLAG_DENY_HULL_SHADER_ROOT_ACCESS
			| D3D12_ROOT_SIGNATURE_FLAG_DENY_DOMAIN_SHADER_ROOT_ACCESS
			| D3D12_ROOT_SIGNATURE_FLAG_DENY_GEOMETRY_SHADER_ROOT_ACCESS
			| D3D12_ROOT_SIGNATURE_FLAG_DENY_AMPLIFICATION_SHADER_ROOT_ACCESS
			| D3D12_ROOT_SIGNATURE_FLAG_DENY_MESH_SHADER_ROOT_ACCESS
	};

	CComPtr<ID3DBlob> signature;
	CComPtr<ID3DBlob> error;
	if (auto hr = D3D12SerializeRootSignature(&computeRootSignatureDesc, D3D_ROOT_SIGNATURE_VERSION_1, &signature, &error); FAILED(hr)) {
		printf("%s\n", (char*)error->GetBufferPointer());
		return hr;
	}

	CComPtr<ID3D12RootSignature> computeRootSignature;
	if (auto hr = device->CreateRootSignature(0, signature->GetBufferPointer(), signature->GetBufferSize(), IID_PPV_ARGS(&computeRootSignature)))
		return hr;

	// Read shader
	std::vector<uint8_t> csData;
	{
		// dxc -T cs_6_0 Z:\compute_shader_test.hlsl -E CSMain -Zi -Fd Z:\compute_shader_test.pdb -Fo Z:\compute_shader_test.fx
		std::ifstream csin(LR"(Z:\compute_shader_test.fx)", std::ios::binary);
		csin.seekg(0, std::ios::end);
		csData.resize(csin.tellg());
		csin.seekg(0, std::ios::beg);
		csin.read((char*)csData.data(), csData.size());
	}

	CComPtr<ID3D12PipelineState> pipelineState;
	D3D12_COMPUTE_PIPELINE_STATE_DESC computePsoDesc = {
		.pRootSignature = computeRootSignature,
		.CS = {
			.pShaderBytecode = csData.data(),
			.BytecodeLength = csData.size(),
		},
		.NodeMask = 0,
		.CachedPSO = {.pCachedBlob = NULL, .CachedBlobSizeInBytes = 0 },
		.Flags = D3D12_PIPELINE_STATE_FLAG_NONE
	};
	if (auto hr = device->CreateComputePipelineState(&computePsoDesc, IID_PPV_ARGS(&pipelineState)))
		return hr;

	CComPtr<ID3D12CommandQueue> cmdQueue;
	CComPtr<ID3D12CommandAllocator> cmdAlloc;
	CComPtr<ID3D12GraphicsCommandList> cmdList;
	{
		D3D12_COMMAND_QUEUE_DESC queueDesc = {
			.Type = D3D12_COMMAND_LIST_TYPE_DIRECT,
			.Priority = 0,
			.Flags = D3D12_COMMAND_QUEUE_FLAG_DISABLE_GPU_TIMEOUT,
			.NodeMask = 0
		};
		if (auto hr = device->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(&cmdQueue)))
			return hr;
		if (auto hr = device->CreateCommandAllocator(queueDesc.Type, IID_PPV_ARGS(&cmdAlloc)))
			return hr;
		if (auto hr = device->CreateCommandList(0, queueDesc.Type, cmdAlloc, nullptr, IID_PPV_ARGS(&cmdList)))
			return hr;
	}

	const auto handleSize = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

	void* rr;
	CComPtr<ID3D12Resource> resIn;
	CComPtr<ID3D12Resource> resInUpload;
	CComPtr<ID3D12Resource> resOut;
	CComPtr<ID3D12DescriptorHeap> heap;
	uint32_t rawFileSize;
	{
		std::vector<uint8_t> fileData;
		{
			std::ifstream csin(LR"(Z:\load25hr1.tex.sqpack)", std::ios::binary);
			csin.seekg(0, std::ios::end);
			fileData.resize(csin.tellg());
			csin.seekg(0, std::ios::beg);
			csin.read((char*)fileData.data(), fileData.size());
		}
		rawFileSize = reinterpret_cast<FileHeader*>(fileData.data())->RawFileSize;

		D3D12_HEAP_PROPERTIES heapProperties{
			.Type = D3D12_HEAP_TYPE_DEFAULT,
			.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
			.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN,
			.CreationNodeMask = 1,
			.VisibleNodeMask = 1
		};
		D3D12_HEAP_PROPERTIES heapUploadProperties{
			.Type = D3D12_HEAP_TYPE_UPLOAD,
			.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
			.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN,
			.CreationNodeMask = 1,
			.VisibleNodeMask = 1
		};
		D3D12_RESOURCE_DESC resourceDesc{
			.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER,
			.Alignment = 0,
			.Width = fileData.size(),
			.Height = 1,
			.DepthOrArraySize = 1,
			.MipLevels = 1,
			.Format = DXGI_FORMAT_UNKNOWN,
			.SampleDesc = {.Count = 1, .Quality = 0 },
			.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
			.Flags = D3D12_RESOURCE_FLAG_NONE
		};
		D3D12_RESOURCE_DESC uploadBufferDesc{
			.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER,
			.Alignment = 0,
			.Width = fileData.size(),
			.Height = 1,
			.DepthOrArraySize = 1,
			.MipLevels = 1,
			.Format = DXGI_FORMAT_UNKNOWN,
			.SampleDesc = {.Count = 1, .Quality = 0 },
			.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
			.Flags = D3D12_RESOURCE_FLAG_NONE
		};
		if (auto hr = device->CreateCommittedResource(&heapProperties, D3D12_HEAP_FLAG_NONE, &resourceDesc, D3D12_RESOURCE_STATE_COMMON, NULL, IID_PPV_ARGS(&resIn)))
			return hr;
		if (auto hr = device->CreateCommittedResource(&heapUploadProperties, D3D12_HEAP_FLAG_NONE, &uploadBufferDesc, D3D12_RESOURCE_STATE_GENERIC_READ, NULL, IID_PPV_ARGS(&resInUpload)))
			return hr;

		D3D12_RANGE rng{};
		if (auto hr = resInUpload->Map(0, &rng, &rr); FAILED(hr))
			return hr;
		memcpy(rr, fileData.data(), fileData.size());
		resInUpload->Unmap(0, nullptr);

		const D3D12_RESOURCE_BARRIER beginCopyBarrier = {
			.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
			.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE,
			.Transition = {
				.pResource = resIn,
				.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
				.StateBefore = D3D12_RESOURCE_STATE_COMMON,
				.StateAfter = D3D12_RESOURCE_STATE_COPY_DEST
			}
		};
		cmdList->ResourceBarrier(1, &beginCopyBarrier);
		cmdList->CopyBufferRegion(resIn, 0, resInUpload, 0, fileData.size());

		D3D12_RESOURCE_BARRIER endCopyBarrier = {
			.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
			.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE,
			.Transition = {
				.pResource = resIn,
				.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
				.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST,
				.StateAfter = D3D12_RESOURCE_STATE_GENERIC_READ
			}
		};
		cmdList->ResourceBarrier(1, &endCopyBarrier);
		const D3D12_SHADER_RESOURCE_VIEW_DESC srvDesc = {
			.Format = DXGI_FORMAT_R32_TYPELESS,
			.ViewDimension = D3D12_SRV_DIMENSION_BUFFER,
			.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
			.Buffer = {
				.FirstElement = 0,
				.NumElements = static_cast<uint32_t>(fileData.size()) / 4,
				.Flags = D3D12_BUFFER_SRV_FLAG_RAW,
			},
		};

		const D3D12_DESCRIPTOR_HEAP_DESC srvUavHeapDesc = {
			// There are two descriptors for the heap. One for SRV buffer, the other for UAV buffer
			.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
			.NumDescriptors = 2,
			.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
			.NodeMask = 0
		};
		if (auto hr = device->CreateDescriptorHeap(&srvUavHeapDesc, IID_PPV_ARGS(&heap)); FAILED(hr))
			return hr;

		// Get the descriptor handle from the descriptor heap.
		auto srvHandle = heap->GetCPUDescriptorHandleForHeapStart();
		// srvHandle will occupy the first slot, so `srvHandle.ptr += 0 * s_srvUavDescriptorSize;`

		// Create the SRV for the buffer with the descriptor handle
		device->CreateShaderResourceView(resIn, &srvDesc, srvHandle);


        heapProperties = {
            .Type = D3D12_HEAP_TYPE_DEFAULT,
            .CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            .MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN,
            .CreationNodeMask = 1,
            .VisibleNodeMask = 1
        };
        resourceDesc = {
            .Dimension = D3D12_RESOURCE_DIMENSION_BUFFER,
            .Alignment = 0,
            .Width = rawFileSize,
            .Height = 1,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = DXGI_FORMAT_UNKNOWN,
            .SampleDesc = {.Count = 1, .Quality = 0 },
            .Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
            .Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS
        };

        // Create the UAV buffer and make it in the unordered access state.
		if (auto hr = device->CreateCommittedResource(&heapProperties, D3D12_HEAP_FLAG_NONE, &resourceDesc, D3D12_RESOURCE_STATE_COMMON, NULL, IID_PPV_ARGS(&resOut)); FAILED(hr))
			return hr;

        // Setup the UAV descriptor. This will be stored in the second slot of the heap.
        D3D12_UNORDERED_ACCESS_VIEW_DESC uavDesc {
            .Format = DXGI_FORMAT_R32_TYPELESS,
            .ViewDimension = D3D12_UAV_DIMENSION_BUFFER,
            .Buffer = {
                .FirstElement = 0,
                .NumElements = rawFileSize / 4,
                .CounterOffsetInBytes = 0,
                .Flags = D3D12_BUFFER_UAV_FLAG_RAW,
            }
        };

        // Get the descriptor handle from the descriptor heap.
        auto uavHandle = srvHandle;
        // uavHandle will occupy the second slot.
        uavHandle.ptr += handleSize;

		device->CreateUnorderedAccessView(resOut, NULL, &uavDesc, uavHandle);
	}

	const auto hFence = CreateEventW(nullptr, true, false, nullptr);
	CComPtr<ID3D12Fence> fence;
	if (auto hr = device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)); FAILED(hr))
		return hr;

	if (auto hr = cmdList->Close(); FAILED(hr))
		return hr;
	cmdQueue->ExecuteCommandLists(1, (ID3D12CommandList**)&cmdList.p);
	if (auto hr = cmdQueue->Signal(fence, 1); FAILED(hr))
		return hr;
	if (auto hr = fence->SetEventOnCompletion(1, hFence); FAILED(hr))
		return hr;
	WaitForSingleObject(hFence, INFINITE);

	CComPtr<ID3D12Resource> readBackBuffer;
	{
		D3D12_HEAP_PROPERTIES heapProperties = {
			.Type = D3D12_HEAP_TYPE_READBACK,
			.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
			.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN,
			.CreationNodeMask = 1,
			.VisibleNodeMask = 1
		};
		D3D12_RESOURCE_DESC resourceDesc = {
			.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER,
			.Alignment = 0,
			.Width = rawFileSize,
			.Height = 1,
			.DepthOrArraySize = 1,
			.MipLevels = 1,
			.Format = DXGI_FORMAT_UNKNOWN,
			.SampleDesc = {.Count = 1, .Quality = 0 },
			.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
			.Flags = D3D12_RESOURCE_FLAG_NONE
		};

		if (auto hr = device->CreateCommittedResource(&heapProperties, D3D12_HEAP_FLAG_NONE, &resourceDesc, D3D12_RESOURCE_STATE_COPY_DEST, NULL, IID_PPV_ARGS(&readBackBuffer)); FAILED(hr))
			return hr;
		if (auto hr = cmdAlloc->Reset(); FAILED(hr))
			return hr;
		if (auto hr = cmdList->Reset(cmdAlloc, pipelineState); FAILED(hr))
			return hr;

		cmdList->SetPipelineState(pipelineState);
		cmdList->SetComputeRootSignature(computeRootSignature);
		cmdList->SetDescriptorHeaps(1, &heap.p);

		auto srvHandle = heap->GetGPUDescriptorHandleForHeapStart();
		auto uavHandle = srvHandle;
		uavHandle.ptr += handleSize;

		cmdList->SetComputeRootDescriptorTable(0, srvHandle);
		cmdList->SetComputeRootDescriptorTable(1, uavHandle);

		// Dispatch the GPU threads
		cmdList->Dispatch(1024, 1, 1);

		// Insert a barrier command to sync the dispatch operation, 
		// and make the UAV buffer object as the copy source.
		D3D12_RESOURCE_BARRIER beginCopyBarrier {
			.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
			.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE,
			.Transition = {
				.pResource = resOut,
				.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
				.StateBefore = D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
				.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE
			}
		};
		cmdList->ResourceBarrier(1, &beginCopyBarrier);
		cmdList->CopyResource(readBackBuffer, resOut);

		D3D12_RESOURCE_BARRIER endCopyBarrier {
			.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
			.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE,
			.Transition = {
				.pResource = resOut,
				.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
				.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE,
				.StateAfter = D3D12_RESOURCE_STATE_UNORDERED_ACCESS
			}
		};
		cmdList->ResourceBarrier(1, &endCopyBarrier);

		if (auto hr = cmdList->Close(); FAILED(hr))
			return hr;
	}

	LARGE_INTEGER qpc;
	QueryPerformanceCounter(&qpc);

	cmdQueue->ExecuteCommandLists(1, (ID3D12CommandList**)&cmdList.p);
	if (auto hr = cmdQueue->Signal(fence, 2); FAILED(hr))
		return hr;
	ResetEvent(hFence);
	if (auto hr = fence->SetEventOnCompletion(2, hFence); FAILED(hr))
		return hr;
	WaitForSingleObject(hFence, INFINITE);

	LARGE_INTEGER qpc2;
	QueryPerformanceCounter(&qpc2);
	printf("Took %d ms\n", (int)((qpc2.QuadPart - qpc.QuadPart) / 10000));

	D3D12_RANGE rng2{0, rawFileSize};
	if (auto hr = readBackBuffer->Map(0, &rng2, &rr); FAILED(hr))
		return hr;
	std::vector<uint8_t> destbuf(rawFileSize, 0);
	memcpy(destbuf.data(), rr, rawFileSize);
	std::ofstream csout(LR"(Z:\load25hr1.tex.test)", std::ios::binary);
	csout.write((char*)destbuf.data(), destbuf.size());

	return 0;
}