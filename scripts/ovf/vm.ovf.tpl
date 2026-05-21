<?xml version="1.0" encoding="UTF-8"?>
<!-- OVF 1.0 descriptor for QNAP Virtualization Station 4.1.x.
     Modeled on a real VS export (sample-debian-13/Sample-debian-13.ovf) so
     the shape is byte-shape-identical to what VS itself emits: vbox namespace
     in the envelope, vmx-08 VirtualSystemType, lsilogic SCSI (with the cidata
     CD attached at SCSI port 1, not IDE), PCNet32 NIC on a "bridged" network,
     EFI firmware via vmw:Config, and a trailing vbox:Machine block mirroring
     the SCSI controller. Rendered by scripts/build-ova.sh via envsubst.

     Variables filled at render time:
       VMNAME DISK_FILENAME SEED_FILENAME DISK_FILE_SIZE SEED_FILE_SIZE
       DISK_CAPACITY_BYTES CPU_COUNT MEMORY_MIB
       DISK_UUID VBOX_MACHINE_UUID MAC_ADDR OVF_CREATION_TS -->
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vmw="http://www.vmware.com/schema/ovf"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xmlns:vbox="http://www.virtualbox.org/ovf/machine">
  <References>
    <File ovf:href="${DISK_FILENAME}" ovf:id="file0" ovf:size="${DISK_FILE_SIZE}"/>
    <File ovf:href="${SEED_FILENAME}" ovf:id="file1" ovf:size="${SEED_FILE_SIZE}"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="${DISK_CAPACITY_BYTES}"
          ovf:diskId="vmdisk0"
          ovf:fileRef="file0"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
          ovf:populatedSize="0"
          qkvmCacheMode="writeback"
          vbox:uuid="${DISK_UUID}"/>
  </DiskSection>
  <NetworkSection>
    <Info>The list of logical networks</Info>
    <Network ovf:name="bridged">
      <Description>The bridged network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="${VMNAME}" ovfCreation="${OVF_CREATION_TS}" osType="${OVF_OS_TYPE}" arch="x86" vsBios="ovmf">
    <Info>A virtual machine</Info>
    <Name>${VMNAME}</Name>
    <OperatingSystemSection ovf:id="102" vmw:osType="otherGuest64">
      <Info>The kind of installed guest operating system</Info>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${VMNAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-08</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>${CPU_COUNT}virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>${CPU_COUNT}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>${MEMORY_MIB}MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>${MEMORY_MIB}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>IDE Controller</rasd:Description>
        <rasd:ElementName>ideController0</rasd:ElementName>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:ResourceType>5</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:Address>1</rasd:Address>
        <rasd:Description>IDE Controller</rasd:Description>
        <rasd:ElementName>ideController1</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceType>5</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>scsiController0</rasd:ElementName>
        <rasd:InstanceID>6</rasd:InstanceID>
        <rasd:ResourceSubType>lsilogic</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>disk0</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk0</rasd:HostResource>
        <rasd:InstanceID>7</rasd:InstanceID>
        <rasd:Parent>6</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>1</rasd:AddressOnParent>
        <rasd:ElementName>cdrom1</rasd:ElementName>
        <rasd:HostResource>ovf:/file/file1</rasd:HostResource>
        <rasd:InstanceID>8</rasd:InstanceID>
        <rasd:Parent>6</rasd:Parent>
        <rasd:ResourceType>15</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:Address>${MAC_ADDR}</rasd:Address>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>bridged</rasd:Connection>
        <rasd:Description>PCNet32 ethernet adapter on &quot;bridged&quot;</rasd:Description>
        <rasd:ElementName>ethernet0</rasd:ElementName>
        <rasd:InstanceID>9</rasd:InstanceID>
        <rasd:ResourceSubType>PCNet32</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="efi"/>
    </VirtualHardwareSection>
    <vbox:Machine ovf:required="false" name="${VMNAME}" OSType="Other_64" uuid="{${VBOX_MACHINE_UUID}}">
      <ovf:Info>Complete VirtualBox machine configuration in VirtualBox format</ovf:Info>
      <Hardware>
        <Memory RAMSize="${MEMORY_MIB}"/>
        <Firmware type="EFI"/>
        <BIOS>
          <IOAPIC enabled="true"/>
        </BIOS>
      </Hardware>
      <StorageControllers>
        <StorageController name="SCSI" type="LsiLogic" PortCount="16" useHostIOCache="false" Bootable="true">
          <AttachedDevice type="HardDisk" hotpluggable="false" port="0" device="0">
            <Image uuid="{${DISK_UUID}}"/>
          </AttachedDevice>
          <AttachedDevice passthrough="false" type="DVD" hotpluggable="false" port="1" device="0"/>
        </StorageController>
      </StorageControllers>
    </vbox:Machine>
  </VirtualSystem>
</Envelope>
