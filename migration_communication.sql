-- ═══════════════════════════════════════════════════════════════
-- ShopFlow Migration — Communication Center
-- One-to-one chats, Group chats, Announcements, and Record discussions
-- Run this in Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- 1. CONVERSATIONS TABLE
CREATE TABLE IF NOT EXISTS public.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('direct', 'group', 'announcement')),
    name TEXT,
    description TEXT,
    created_by TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_message_at TIMESTAMPTZ DEFAULT NOW(),
    last_message_preview TEXT
);

CREATE INDEX IF NOT EXISTS idx_conversations_shop_id ON public.conversations(shop_id);
CREATE INDEX IF NOT EXISTS idx_conversations_type ON public.conversations(type);
CREATE INDEX IF NOT EXISTS idx_conversations_last_message ON public.conversations(last_message_at DESC);

-- 2. CONVERSATION MEMBERS TABLE
CREATE TABLE IF NOT EXISTS public.conversation_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE NOT NULL,
    shop_id UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    user_id TEXT NOT NULL,
    user_name TEXT,
    user_role TEXT,
    unread_count INT DEFAULT 0,
    last_read_at TIMESTAMPTZ DEFAULT NOW(),
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(conversation_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_conv_members_user ON public.conversation_members(user_id);
CREATE INDEX IF NOT EXISTS idx_conv_members_conv ON public.conversation_members(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conv_members_shop ON public.conversation_members(shop_id);

-- 3. MESSAGES TABLE
CREATE TABLE IF NOT EXISTS public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE NOT NULL,
    shop_id UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    sender_id TEXT NOT NULL,
    sender_name TEXT,
    sender_role TEXT,
    sender_type TEXT,
    content TEXT NOT NULL,
    reply_to_id UUID REFERENCES public.messages(id) ON DELETE SET NULL,
    record_type TEXT, -- 'invoice', 'product', 'customer', 'return', 'stock'
    record_id TEXT,
    record_ref TEXT,
    record_data JSONB,
    is_pinned BOOLEAN DEFAULT FALSE,
    pinned_by TEXT,
    reactions JSONB DEFAULT '{}'::jsonb,
    attachments JSONB DEFAULT '[]'::jsonb,
    edited_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(conversation_id, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_messages_shop ON public.messages(shop_id);

-- 4. ANNOUNCEMENTS TABLE
CREATE TABLE IF NOT EXISTS public.announcements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id UUID REFERENCES public.shops(id) ON DELETE CASCADE NOT NULL,
    sender_id TEXT NOT NULL,
    sender_name TEXT,
    sender_role TEXT,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    priority TEXT DEFAULT 'normal' CHECK (priority IN ('normal', 'important', 'urgent')),
    target_audience TEXT DEFAULT 'everyone' CHECK (target_audience IN ('everyone', 'managers', 'staff', 'group', 'targeted')),
    target_group_id UUID REFERENCES public.conversations(id) ON DELETE SET NULL,
    target_user_ids JSONB DEFAULT '[]'::jsonb,
    acknowledgements JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_announcements_shop ON public.announcements(shop_id, created_at DESC);

-- 5. ENABLE ROW LEVEL SECURITY
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

-- 6. POLICIES WITH SHOP ISOLATION
DROP POLICY IF EXISTS "Strict Shop isolation for conversations" ON public.conversations;
CREATE POLICY "Strict Shop isolation for conversations" ON public.conversations
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

DROP POLICY IF EXISTS "Strict Shop isolation for conversation_members" ON public.conversation_members;
CREATE POLICY "Strict Shop isolation for conversation_members" ON public.conversation_members
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

DROP POLICY IF EXISTS "Strict Shop isolation for messages" ON public.messages;
CREATE POLICY "Strict Shop isolation for messages" ON public.messages
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

DROP POLICY IF EXISTS "Strict Shop isolation for announcements" ON public.announcements;
CREATE POLICY "Strict Shop isolation for announcements" ON public.announcements
    FOR ALL USING (public.is_authorized_for_shop(shop_id));

-- 7. DUPLICATE DIRECT CHAT PREVENTION RPC
CREATE OR REPLACE FUNCTION public.get_or_create_direct_conversation(
    p_shop_id UUID,
    p_user1_id TEXT,
    p_user1_name TEXT,
    p_user1_role TEXT,
    p_user2_id TEXT,
    p_user2_name TEXT,
    p_user2_role TEXT
)
RETURNS UUID AS $$
DECLARE
    v_conv_id UUID;
BEGIN
    -- Check if a direct conversation already exists containing both members
    SELECT cm1.conversation_id INTO v_conv_id
    FROM public.conversation_members cm1
    JOIN public.conversation_members cm2 ON cm1.conversation_id = cm2.conversation_id
    JOIN public.conversations c ON c.id = cm1.conversation_id
    WHERE c.shop_id = p_shop_id
      AND c.type = 'direct'
      AND cm1.user_id = p_user1_id
      AND cm2.user_id = p_user2_id
    LIMIT 1;

    IF v_conv_id IS NOT NULL THEN
        RETURN v_conv_id;
    END IF;

    -- Create new direct conversation
    INSERT INTO public.conversations (shop_id, type, name, created_by)
    VALUES (p_shop_id, 'direct', p_user2_name, p_user1_id)
    RETURNING id INTO v_conv_id;

    -- Insert member 1
    INSERT INTO public.conversation_members (conversation_id, shop_id, user_id, user_name, user_role)
    VALUES (v_conv_id, p_shop_id, p_user1_id, p_user1_name, p_user1_role);

    -- Insert member 2
    INSERT INTO public.conversation_members (conversation_id, shop_id, user_id, user_name, user_role)
    VALUES (v_conv_id, p_shop_id, p_user2_id, p_user2_name, p_user2_role);

    RETURN v_conv_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_or_create_direct_conversation TO authenticated, anon;

-- 8. TRIGGER TO UPDATE CONVERSATION LAST MESSAGE AND UNREAD COUNTERS
CREATE OR REPLACE FUNCTION public.on_message_inserted()
RETURNS TRIGGER AS $$
BEGIN
    -- Update conversation preview and timestamp
    UPDATE public.conversations
    SET last_message_at = NEW.created_at,
        last_message_preview = SUBSTRING(NEW.content FROM 1 FOR 80)
    WHERE id = NEW.conversation_id;

    -- Increment unread_count for other members in this conversation
    UPDATE public.conversation_members
    SET unread_count = unread_count + 1
    WHERE conversation_id = NEW.conversation_id
      AND user_id != NEW.sender_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_message_inserted ON public.messages;
CREATE TRIGGER trg_message_inserted
AFTER INSERT ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.on_message_inserted();

-- 9. ADD TABLES TO SUPABASE REALTIME (if enabled)
DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.announcements;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
