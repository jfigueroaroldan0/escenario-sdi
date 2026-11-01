<?xml version="1.0"?>
<!-- El provider libvirt no distingue CD-ROM ni bus de disco: por defecto
     engancha todos los discos como virtio. Windows no ve virtio sin drivers,
     así que aquí reescribimos los dispositivos del dominio Windows:
       - el disco del sistema (.qcow2) -> SATA (sda), device='disk'
       - los tres ISO                  -> SATA, device='cdrom', solo lectura
     El orden de arranque (cdrom, hd) lo pone boot_device en windows.tf. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>

  <!-- Identidad: copia todo tal cual salvo lo que reescribimos abajo -->
  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>

  <!-- Disco del sistema -->
  <xsl:template match="/domain/devices/disk[contains(source/@file,'escenario-windows.qcow2')]">
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <xsl:copy-of select="source"/>
      <target dev="sda" bus="sata"/>
    </disk>
  </xsl:template>

  <!-- ISO de instalación de Windows -->
  <xsl:template match="/domain/devices/disk[contains(source/@file,'win10.iso')]">
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <xsl:copy-of select="source"/>
      <target dev="sdb" bus="sata"/>
      <readonly/>
    </disk>
  </xsl:template>

  <!-- ISO del autounattend (+ firstlogon.ps1) -->
  <xsl:template match="/domain/devices/disk[contains(source/@file,'unattend.iso')]">
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <xsl:copy-of select="source"/>
      <target dev="sdc" bus="sata"/>
      <readonly/>
    </disk>
  </xsl:template>

  <!-- ISO virtio-win (guest tools) -->
  <xsl:template match="/domain/devices/disk[contains(source/@file,'virtio.iso')]">
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <xsl:copy-of select="source"/>
      <target dev="sdd" bus="sata"/>
      <readonly/>
    </disk>
  </xsl:template>

  <!-- El provider pone las tarjetas en virtio (Windows no lo ve sin drivers):
       se cambian a e1000e, que Windows reconoce de fábrica -->
  <xsl:template match="/domain/devices/interface/model/@type">
    <xsl:attribute name="type">e1000e</xsl:attribute>
  </xsl:template>
</xsl:stylesheet>
