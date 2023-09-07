<?xml version="1.0" ?>
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>
  <xsl:template match="node()|@*">
     <xsl:copy>
       <xsl:apply-templates select="node()|@*"/>
     </xsl:copy>
  </xsl:template>

  <xsl:template match="/domain/devices">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>

      <interface type='udp'>
        <model type='virtio'/>
        <address type='pci' domain='0x0000' bus='0x00' slot='0x10' function='0x0'/>
        <mac address='52:54:00:ee:ee:03'/>
        <source address='127.1.${topology_id}.3' port='10002'>
          <local address='127.1.${topology_id}.2' port='10001'/>
        </source>
      </interface>

      <interface type='udp'>
        <model type='virtio'/>
        <address type='pci' domain='0x0000' bus='0x00' slot='0x11' function='0x0'/>
        <mac address='52:54:00:ee:ee:04'/>
        <source address='127.1.${topology_id}.4' port='10002'>
          <local address='127.1.${topology_id}.2' port='10002'/>
        </source>
      </interface>

    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
