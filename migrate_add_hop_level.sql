-- Add hop_level column to nodes table
-- hop_level: 1 = first hop, 2 = second hop, 3 = third hop

ALTER TABLE nodes ADD COLUMN hop_level INTEGER DEFAULT 1;

-- Create index for faster queries
CREATE INDEX IF NOT EXISTS idx_nodes_hop_level ON nodes(hop_level, enabled);

-- Update existing nodes to first hop by default
UPDATE nodes SET hop_level = 1 WHERE hop_level IS NULL;
